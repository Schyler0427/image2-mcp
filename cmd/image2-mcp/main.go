package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"

	"image2-mcp/internal/image2"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const serverVersion = "0.4.4"
const binaryIdentity = "image2-mcp " + serverVersion + " offline-v1"

type generateParams struct {
	Prompt          string `json:"prompt" jsonschema:"Image prompt to generate."`
	Version         string `json:"version,omitempty" jsonschema:"Optional image version: 2.0, 2.5, 2.6 (Sunburst), or 2.6-flare. PNG omission uses the maintainer default, normally Image 2.0; GIF omission uses 2.6-flare. Never override an explicit model after failure."`
	Size            string `json:"size,omitempty" jsonschema:"Image size: PNG defaults to 1024x1024; GIF defaults to auto."`
	OutputFormat    string `json:"output_format,omitempty" jsonschema:"png (default) or gif. 生成动图 / GIF / 循环动图 requests use gif and default to Image2.6 Flare if version is omitted. GIF is generation-only; default size auto."`
	Quality         string `json:"quality,omitempty" jsonschema:"Optional image quality: auto, low, medium or high."`
	FrameCount      *int   `json:"frame_count,omitempty" jsonschema:"GIF only: 2 to 64 frames, default 9. Omit for PNG."`
	FrameDurationMS *int   `json:"frame_duration_ms,omitempty" jsonschema:"GIF only: 20 to 2000 ms per frame, default 200; service rounds to 10 ms. Omit for PNG."`
	OutputDir       string `json:"output_dir,omitempty" jsonschema:"Optional absolute directory to save the PNG or GIF."`
	OutputName      string `json:"output_name,omitempty" jsonschema:"Optional output file name with .png or .gif matching the selected format."`
}

type editParams struct {
	Prompt       string   `json:"prompt" jsonschema:"Image prompt for the edit."`
	Version      string   `json:"version,omitempty" jsonschema:"Optional image version: 2.0, 2.5, 2.6 (Sunburst), or 2.6-flare. Omit for the maintainer default, normally Image 2.0."`
	OutputFormat string   `json:"output_format,omitempty" jsonschema:"PNG only. GIF is generation-only and is not supported for editing reference images."`
	ImagePaths   []string `json:"image_paths" jsonschema:"Absolute paths to source images, preserved in request order. At least one required."`
	Size         string   `json:"size,omitempty" jsonschema:"Image size, defaults to 1024x1024."`
	Quality      string   `json:"quality,omitempty" jsonschema:"Image quality, defaults to auto."`
	OutputDir    string   `json:"output_dir,omitempty" jsonschema:"Optional absolute directory to save the PNG."`
	OutputName   string   `json:"output_name,omitempty" jsonschema:"Optional PNG file name. Defaults to image2-{timestamp}.png."`
	MaskPath     string   `json:"mask_path,omitempty" jsonschema:"Optional absolute path to a mask PNG."`
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Printf("%s %s %s\n", binaryIdentity, runtime.GOOS, runtime.GOARCH)
		return nil
	}
	projectRoot, err := findProjectRoot()
	if err != nil {
		return err
	}
	outputDir := filepath.Join(projectRoot, "output", "imagegen")
	if len(os.Args) == 2 && os.Args[1] == "--verify-mcp" {
		return verifyInstallation(outputDir)
	}
	if len(os.Args) > 1 {
		return fmt.Errorf("unsupported arguments; use --verify-mcp for a local connection check")
	}
	server := newServer(projectRoot, outputDir)
	return server.Run(context.Background(), &mcp.StdioTransport{})
}

func newServer(projectRoot, outputDir string) *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{
		Name:    "image2-mcp",
		Version: serverVersion,
	}, &mcp.ServerOptions{
		Instructions: "Natural-language image requests such as \"帮我生成一张图\" call generate_image. The default is Image2 (Image 2.0), model: \"image2\". Only explicit 使用 Gemini 生图 / 香蕉生图 / banana 生图 requests select model: \"gemini\" (Gemini 3.1 Flash Image). User phrases \"使用 image2\" or Image2 select model: \"image2\" (Image 2.0), and Image2.5 / \"用 2.5 生图\" select model: \"image2.5\" (Image 2.5). For an existing image, photo, attachment or reference image, call edit_image directly with the same model selection. Masks are supported by Image2 only. Do not use Computer Use, browser navigation, screenshots, or generic file tools for the transformation. Preserve the user's task details, subject, style, pose, and composition. Pass all image paths in order; ~ paths are supported. Gemini uses aspect_ratio and image_size 1K/2K/4K. Image2 uses size and optional edit quality/mask_path. Legacy generate_image2/edit_image2 always use Image2; call edit_image2 only for an explicit Image2 compatibility request. Image 2.5 requests must pass version: \"2.5\" when using legacy tools. OPENAI_IMAGE_MODEL only controls the legacy Image2 default. Image2 and Gemini have independent image keys; never reuse another service key or silently switch models after an error. Do not automatically repeat failed image calls. Do not ask the user for a Base URL, model ID, endpoint, Go, Git, or admin permission. Ordinary requests save PNG. Explicit 用2.6生图 selects model: \"image2.6\" (Sunburst); 用2.6快速版生图 selects model: \"image2.6-flare\". Requests such as 生成动图 / 做个 GIF / 循环动图 / animated GIF automatically call generate_image with output_format: \"gif\" and model: \"image2.6-flare\" unless the user specified a model; omit size for auto, frame_count defaults to 9 and frame_duration_ms to 200. GIF requests do not change the ordinary Image2 PNG default. Never override an explicit user model; older Image2 and Gemini cannot generate GIF through these tools. GIF is generation-only: if reference images need animation, explain that image editing does not support GIF and never silently drop the references. GIF results keep all animation frames and use a .gif file. Return saved local paths.",
	})

	mcp.AddTool(server, &mcp.Tool{
		Name:        "generate_image2",
		Description: "Legacy Image2-only PNG or GIF generation. Use generate_image for general requests (ordinary PNG default Image2). PNG uses Image 2.0 unless OPENAI_IMAGE_MODEL is set; Image 2.5 requests must pass version: \"2.5\". Image2.6 uses version 2.6 (Sunburst) or 2.6-flare. For 生成动图 / GIF / 循环动图 use output_format=gif; no version selects 2.6-flare. GIF is generation-only; preserve an explicit version and never switch after failure.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, params generateParams) (*mcp.CallToolResult, image2.GenerateResult, error) {
		frameCount, frameDurationMS, err := generationAnimationValues(params.OutputFormat, params.FrameCount, params.FrameDurationMS)
		if err != nil {
			return nil, image2.GenerateResult{}, err
		}
		client, err := image2.NewFromEnv(outputDir)
		if err != nil {
			return nil, image2.GenerateResult{}, err
		}
		result, err := client.Generate(ctx, image2.GenerateRequest{
			Prompt:          params.Prompt,
			Version:         generationVersion(params.Version, params.OutputFormat),
			Size:            params.Size,
			OutputFormat:    params.OutputFormat,
			Quality:         params.Quality,
			FrameCount:      frameCount,
			FrameDurationMS: frameDurationMS,
			OutputDir:       params.OutputDir,
			OutputName:      params.OutputName,
		})
		if err != nil {
			return nil, image2.GenerateResult{}, err
		}
		text, err := json.MarshalIndent(result, "", "  ")
		if err != nil {
			return nil, image2.GenerateResult{}, err
		}
		return &mcp.CallToolResult{
			Content: []mcp.Content{
				&mcp.TextContent{Text: string(text)},
			},
		}, result, nil
	})

	mcp.AddTool(server, &mcp.Tool{
		Name:        "edit_image2",
		Description: "Legacy Image2-only PNG reference editing with optional mask. GIF output and reference animation are unsupported. Use edit_image for general reference editing (default Image2). For an explicit Image2 compatibility request, call edit_image2 directly. Preserve the user's task details and source path order; ~ paths are supported. Do not use Computer Use. Omit version for legacy Image 2.0 default; Image 2.5 requires version: \"2.5\"; Image2.6 uses 2.6 (Sunburst) or 2.6-flare.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, params editParams) (*mcp.CallToolResult, image2.EditResult, error) {
		if err := validateEditOutputFormat(params.OutputFormat); err != nil {
			return nil, image2.EditResult{}, err
		}
		client, err := image2.NewFromEnv(outputDir)
		if err != nil {
			return nil, image2.EditResult{}, err
		}
		result, err := client.Edit(ctx, image2.EditRequest{
			Prompt:     params.Prompt,
			Version:    params.Version,
			Size:       params.Size,
			Quality:    params.Quality,
			OutputDir:  params.OutputDir,
			OutputName: params.OutputName,
			ImagePaths: params.ImagePaths,
			MaskPath:   params.MaskPath,
		})
		if err != nil {
			return nil, image2.EditResult{}, err
		}
		text, err := json.MarshalIndent(result, "", "  ")
		if err != nil {
			return nil, image2.EditResult{}, err
		}
		return &mcp.CallToolResult{
			Content: []mcp.Content{
				&mcp.TextContent{Text: string(text)},
			},
		}, result, nil
	})

	registerUnifiedImageTools(server, outputDir)
	return server
}

func findProjectRoot() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("resolve executable path: %w", err)
	}
	dir := filepath.Dir(exe)
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	wd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("resolve working directory: %w", err)
	}
	return wd, nil
}
