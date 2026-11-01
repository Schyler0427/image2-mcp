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
	Prompt      string `json:"prompt" jsonschema:"Image prompt, preserving the user request in full."`
	Model       string `json:"model,omitempty" jsonschema:"image2 (default, Image 2.0), image2.5 (Image 2.5), or gemini (Gemini 3.1 Flash Image, also banana/香蕉). Select Gemini only when explicitly requested. Never switch providers after an error."`
	Size        string `json:"size,omitempty" jsonschema:"Image2 only: pixel size such as 1024x1024. Omit for Gemini."`
	AspectRatio string `json:"aspect_ratio,omitempty" jsonschema:"Gemini only: output aspect ratio such as 1:1, 16:9 or 9:16. Default 1:1."`
	ImageSize   string `json:"image_size,omitempty" jsonschema:"Gemini only: resolution tier 1K, 2K or 4K. Default 1K."`
	OutputDir   string `json:"output_dir,omitempty" jsonschema:"Optional absolute or tilde-expanded output directory."`
	OutputName  string `json:"output_name,omitempty" jsonschema:"Optional PNG file name."`
}

type unifiedEditParams struct {
	Prompt      string   `json:"prompt" jsonschema:"Image editing prompt, preserving the user request in full."`
	Model       string   `json:"model,omitempty" jsonschema:"image2 (default, Image 2.0), image2.5 (Image 2.5), or gemini (Gemini 3.1 Flash Image, also banana/香蕉). Select Gemini only when explicitly requested. Never switch providers after an error."`
	ImagePaths  []string `json:"image_paths" jsonschema:"Absolute or tilde-expanded source image paths in user-provided order. At least one required."`
	Size        string   `json:"size,omitempty" jsonschema:"Image2 only: pixel size such as 1024x1024. Omit for Gemini."`
	Quality     string   `json:"quality,omitempty" jsonschema:"Image2 only: image quality. Omit for Gemini."`
	MaskPath    string   `json:"mask_path,omitempty" jsonschema:"Image2 only: optional PNG mask path. Gemini native reference editing has no mask field."`
	AspectRatio string   `json:"aspect_ratio,omitempty" jsonschema:"Gemini only: output aspect ratio. Default 1:1."`
	ImageSize   string   `json:"image_size,omitempty" jsonschema:"Gemini only: resolution tier 1K, 2K or 4K. Default 1K."`
	OutputDir   string   `json:"output_dir,omitempty" jsonschema:"Optional absolute or tilde-expanded output directory."`
	OutputName  string   `json:"output_name,omitempty" jsonschema:"Optional PNG file name."`
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
	default:
		return "", errors.New("model must be gemini (Gemini 3.1 Flash Image), image2 or image2.5")
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
	if provider == "image2.5" {
		return "2.5"
	}
	return "2.0"
}

func registerUnifiedImageTools(server *mcp.Server, outputDir string) {
	mcp.AddTool(server, &mcp.Tool{
		Name:        "generate_image",
		Description: "Generate and save a PNG. Use this for natural-language image generation. The default is Image2 (Image 2.0, model=image2); Image2.5 / 用 2.5 生图 uses model=image2.5. Only explicit 使用 Gemini 生图 / 香蕉生图 / banana 生图 requests use model=gemini (Gemini 3.1 Flash Image). Gemini supports aspect_ratio and image_size (1K/2K/4K); Image2 uses size. Do not change the selected model after an error.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, params unifiedGenerateParams) (*mcp.CallToolResult, image2.GenerateResult, error) {
		provider, err := selectedImageProvider(params.Model)
		if err != nil {
			return nil, image2.GenerateResult{}, err
		}
		var result image2.GenerateResult
		if provider == "gemini" {
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
			result, err = client.Generate(ctx, image2.GenerateRequest{Prompt: params.Prompt, Version: image2VersionForProvider(provider), Size: params.Size, OutputDir: params.OutputDir, OutputName: params.OutputName})
			if err != nil {
				return nil, result, err
			}
		}
		return unifiedImageResult(result)
	})

	mcp.AddTool(server, &mcp.Tool{
		Name:        "edit_image",
		Description: "Edit local reference images and save a PNG. Use directly for an existing image, photo, attachment or reference; keep source paths in order. The default is Image2 (Image 2.0, model=image2); Image2.5 uses model=image2.5. Only explicit Gemini / 香蕉生图 / banana 生图 requests use model=gemini (Gemini 3.1 Flash Image). Masks and quality are available for Image2 only. Do not use Computer Use or silently switch models.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, params unifiedEditParams) (*mcp.CallToolResult, image2.GenerateResult, error) {
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
