package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"

	"image2-mcp/internal/gemini"
	"image2-mcp/internal/image2"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const defaultGeminiImageModel = "gemini-3.1-flash-image"

type unifiedGenerateParams struct {
	Prompt          string `json:"prompt" jsonschema:"Image prompt, preserving the user request in full."`
	Model           string `json:"model,omitempty" jsonschema:"image2 (ordinary PNG default, Image 2.0), image2.5, image2.6 (Sunburst), image2.6-flare (快速版), or gemini (Gemini 3.1 Flash Image, also banana/香蕉). GIF without a specified model uses image2.6-flare. Never change an explicitly selected model or provider after an error."`
	Size            string `json:"size,omitempty" jsonschema:"Image2 only: PNG defaults to 1024x1024; GIF defaults to auto, or use positive dimensions divisible by 16. Omit for Gemini."`
	OutputFormat    string `json:"output_format,omitempty" jsonschema:"png (default) or gif. For 生成动图 / GIF / 循环动图 choose gif; without a specified model select image2.6-flare. GIF is Image2.6 generation only and defaults to auto size."`
	Quality         string `json:"quality,omitempty" jsonschema:"Image2 only: auto, low, medium or high. Omit for Gemini."`
	FrameCount      *int   `json:"frame_count,omitempty" jsonschema:"GIF only: 2 to 64 animation frames; defaults to 9. Omit for PNG and Gemini."`
	FrameDurationMS *int   `json:"frame_duration_ms,omitempty" jsonschema:"GIF only: 20 to 2000 milliseconds per frame; defaults to 200. The service rounds to 10 ms. Omit for PNG and Gemini."`
	AspectRatio     string `json:"aspect_ratio,omitempty" jsonschema:"Gemini only: output aspect ratio such as 1:1, 16:9 or 9:16. Default 1:1."`
	ImageSize       string `json:"image_size,omitempty" jsonschema:"Gemini only: resolution tier 1K, 2K or 4K. Default 1K."`
	OutputDir       string `json:"output_dir,omitempty" jsonschema:"Optional absolute or tilde-expanded output directory."`
	OutputName      string `json:"output_name,omitempty" jsonschema:"Optional output file name; saved with .png or .gif matching the selected format."`
}

type unifiedEditParams struct {
	Prompt       string   `json:"prompt" jsonschema:"Image editing prompt, preserving the user request in full."`
	Model        string   `json:"model,omitempty" jsonschema:"image2 (default, Image 2.0), image2.5, image2.6 (Sunburst), image2.6-flare (快速版), or gemini (Gemini 3.1 Flash Image, also banana/香蕉). Select Gemini only when explicitly requested. Never switch providers after an error."`
	OutputFormat string   `json:"output_format,omitempty" jsonschema:"PNG only. GIF is supported by generation tools only; editing or animating a reference image as GIF is unavailable."`
	ImagePaths   []string `json:"image_paths" jsonschema:"Absolute or tilde-expanded source image paths in user-provided order. At least one required."`
	Size         string   `json:"size,omitempty" jsonschema:"Image2 only: pixel size such as 1024x1024. Omit for Gemini."`
	Quality      string   `json:"quality,omitempty" jsonschema:"Image2 only: image quality. Omit for Gemini."`
	MaskPath     string   `json:"mask_path,omitempty" jsonschema:"Image2 only: optional PNG mask path. Gemini native reference editing has no mask field."`
	AspectRatio  string   `json:"aspect_ratio,omitempty" jsonschema:"Gemini only: output aspect ratio. Default 1:1."`
	ImageSize    string   `json:"image_size,omitempty" jsonschema:"Gemini only: resolution tier 1K, 2K or 4K. Default 1K."`
	OutputDir    string   `json:"output_dir,omitempty" jsonschema:"Optional absolute or tilde-expanded output directory."`
	OutputName   string   `json:"output_name,omitempty" jsonschema:"Optional PNG file name."`
}

func selectedImageProvider(raw string) (string, error) {
	normalized := strings.NewReplacer(" ", "", "-", "", "_", "").Replace(strings.ToLower(strings.TrimSpace(raw)))
	switch normalized {
	case "gemini", "gemini3.1flash", "gemini3.1flashimage", "3.1flash", "banana", "香蕉":
		return "gemini", nil
	case "", "image2", "image2.0", "2", "2.0":
		return "image2", nil
	case "image2.5", "2.5":
		return "image2.5", nil
	case "image2.6", "2.6", "image2.6sunburst", "2.6sunburst":
		return "image2.6", nil
	case "image2.6flare", "2.6flare", "image2.6快速版", "2.6快速版", "image2.6fast", "2.6fast":
		return "image2.6-flare", nil
	default:
		return "", errors.New("model must be image2, image2.5, image2.6 (Sunburst), image2.6-flare or gemini (Gemini 3.1 Flash Image)")
	}
}

func newGeminiImageClient(outputDir string) (*gemini.Client, error) {
	key := strings.TrimSpace(os.Getenv("GEMINI_IMAGE_API_KEY"))
	if key == "" {
		return nil, errors.New("GEMINI_IMAGE_API_KEY is required; configure the dedicated Gemini image key")
	}
	baseURL := strings.TrimSpace(os.Getenv("GEMINI_IMAGE_BASE_URL"))
	if baseURL == "" {
		baseURL = image2.DefaultBaseURL
	}
	model := strings.TrimSpace(os.Getenv("GEMINI_IMAGE_MODEL"))
	if model == "" {
		model = defaultGeminiImageModel
	}
	return gemini.New(key, baseURL, model, outputDir, nil)
}

func image2VersionForProvider(provider string) string {
	switch provider {
	case "image2.5":
		return "2.5"
	case "image2.6":
		return "2.6"
	case "image2.6-flare":
		return "2.6-flare"
	}
	return "2.0"
}

func validateEditOutputFormat(format string) error {
	if normalized := strings.ToLower(strings.TrimSpace(format)); normalized != "" && normalized != "png" {
		return errors.New("edit tools save PNG only; GIF output is supported only by image generation, not reference-image editing")
	}
	return nil
}

func generationVersion(version, format string) string {
	if strings.TrimSpace(version) == "" && strings.EqualFold(strings.TrimSpace(format), "gif") {
		return "2.6-flare"
	}
	return version
}

func generationAnimationValues(format string, frameCount, frameDurationMS *int) (int, int, error) {
	if !strings.EqualFold(strings.TrimSpace(format), "gif") {
		if frameCount != nil || frameDurationMS != nil {
			return 0, 0, errors.New("frame_count and frame_duration_ms require GIF output_format")
		}
		return 0, 0, nil
	}
	count, duration := 0, 0
	if frameCount != nil {
		count = *frameCount
		if count < 2 || count > 64 {
			return 0, 0, errors.New("frame_count must be between 2 and 64")
		}
	}
	if frameDurationMS != nil {
		duration = *frameDurationMS
		if duration < 20 || duration > 2000 {
			return 0, 0, errors.New("frame_duration_ms must be between 20 and 2000")
		}
	}
	return count, duration, nil
}

func registerUnifiedImageTools(server *mcp.Server, outputDir string) {
	mcp.AddTool(server, &mcp.Tool{
		Name:        "generate_image",
		Description: "Generate and save a PNG or animated GIF. Ordinary image requests default to Image2 (Image 2.0, model=image2). Explicit 用 2.5 生图 uses image2.5; 用2.6生图 uses image2.6 (Sunburst); 用2.6快速版生图 uses image2.6-flare. For 生成动图 / GIF / 循环动图 use output_format=gif and image2.6-flare unless the user specified a model; GIF with no model automatically selects Flare. GIF defaults to auto size, 9 frames and 200 ms/frame. Only explicit 使用 Gemini 生图 / 香蕉生图 / banana 生图 selects gemini (Gemini 3.1 Flash Image). Gemini supports aspect_ratio and image_size (1K/2K/4K); Image2 uses size. Never change an explicit model or switch after an error.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, params unifiedGenerateParams) (*mcp.CallToolResult, image2.GenerateResult, error) {
		frameCount, frameDurationMS, err := generationAnimationValues(params.OutputFormat, params.FrameCount, params.FrameDurationMS)
		if err != nil {
			return nil, image2.GenerateResult{}, err
		}
		provider, err := selectedImageProvider(params.Model)
		if err != nil {
			return nil, image2.GenerateResult{}, err
		}
		if strings.TrimSpace(params.Model) == "" && strings.EqualFold(strings.TrimSpace(params.OutputFormat), "gif") {
			provider = "image2.6-flare"
		}
		var result image2.GenerateResult
		if provider == "gemini" {
			format := strings.ToLower(strings.TrimSpace(params.OutputFormat))
			if (format != "" && format != "png") || params.Quality != "" || params.FrameCount != nil || params.FrameDurationMS != nil {
				return nil, result, errors.New("Gemini saves PNG only and does not support Image2 GIF, quality or animation parameters")
			}
			if params.Size != "" {
				return nil, result, errors.New("Gemini uses aspect_ratio and image_size; omit the Image2-only size field")
			}
			client, err := newGeminiImageClient(outputDir)
			if err != nil {
				return nil, result, err
			}
			r, err := client.Generate(ctx, gemini.Request{Prompt: params.Prompt, AspectRatio: params.AspectRatio, ImageSize: params.ImageSize, OutputDir: params.OutputDir, OutputName: params.OutputName})
			if err != nil {
				return nil, result, err
			}
			result = image2.GenerateResult{FilePath: r.FilePath, Model: r.Model, Size: r.Size}
		} else {
			if params.AspectRatio != "" || params.ImageSize != "" {
				return nil, result, errors.New("Image2 uses size; aspect_ratio and image_size are Gemini-only fields")
			}
			client, err := image2.NewFromEnv(outputDir)
			if err != nil {
				return nil, result, err
			}
			result, err = client.Generate(ctx, image2.GenerateRequest{Prompt: params.Prompt, Version: image2VersionForProvider(provider), Size: params.Size, OutputFormat: params.OutputFormat, Quality: params.Quality, FrameCount: frameCount, FrameDurationMS: frameDurationMS, OutputDir: params.OutputDir, OutputName: params.OutputName})
			if err != nil {
				return nil, result, err
			}
		}
		return unifiedImageResult(result)
	})

	mcp.AddTool(server, &mcp.Tool{
		Name:        "edit_image",
		Description: "Edit local reference images and save a PNG. GIF output and animating a reference image are not supported by the edit endpoint; do not silently discard reference images to call generation. Use directly for an existing image, photo, attachment or reference; keep source paths in order. The default is Image2 (Image 2.0, model=image2); explicit Image2.5 uses image2.5, Image2.6 uses image2.6 (Sunburst), and Image2.6 快速版 uses image2.6-flare. Only explicit Gemini / 香蕉生图 / banana 生图 requests use model=gemini (Gemini 3.1 Flash Image). Masks and quality are available for Image2 only. Do not use Computer Use or silently switch models.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, params unifiedEditParams) (*mcp.CallToolResult, image2.GenerateResult, error) {
		if err := validateEditOutputFormat(params.OutputFormat); err != nil {
			return nil, image2.GenerateResult{}, err
		}
		provider, err := selectedImageProvider(params.Model)
		if err != nil {
			return nil, image2.GenerateResult{}, err
		}
		var result image2.GenerateResult
		if provider == "gemini" {
			if params.MaskPath != "" {
				return nil, result, errors.New("Gemini native reference editing does not support mask_path; request Image2 explicitly for masked editing")
			}
			if params.Size != "" || params.Quality != "" {
				return nil, result, errors.New("Gemini uses aspect_ratio and image_size; omit Image2-only size and quality")
			}
			client, err := newGeminiImageClient(outputDir)
			if err != nil {
				return nil, result, err
			}
			r, err := client.Edit(ctx, gemini.Request{Prompt: params.Prompt, ImagePaths: params.ImagePaths, AspectRatio: params.AspectRatio, ImageSize: params.ImageSize, OutputDir: params.OutputDir, OutputName: params.OutputName})
			if err != nil {
				return nil, result, err
			}
			result = image2.GenerateResult{FilePath: r.FilePath, Model: r.Model, Size: r.Size}
		} else {
			if params.AspectRatio != "" || params.ImageSize != "" {
				return nil, result, errors.New("Image2 uses size; aspect_ratio and image_size are Gemini-only fields")
			}
			client, err := image2.NewFromEnv(outputDir)
			if err != nil {
				return nil, result, err
			}
			result, err = client.Edit(ctx, image2.EditRequest{Prompt: params.Prompt, Version: image2VersionForProvider(provider), ImagePaths: params.ImagePaths, Size: params.Size, Quality: params.Quality, MaskPath: params.MaskPath, OutputDir: params.OutputDir, OutputName: params.OutputName})
			if err != nil {
				return nil, result, err
			}
		}
		return unifiedImageResult(result)
	})
}

func unifiedImageResult(result image2.GenerateResult) (*mcp.CallToolResult, image2.GenerateResult, error) {
	encoded, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return nil, result, err
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(encoded)}}}, result, nil
}
