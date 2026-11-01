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

const serverVersion = "0.4.2"
const binaryIdentity = "image2-mcp " + serverVersion + " offline-v1"

type generateParams struct {
	Prompt     string `json:"prompt" jsonschema:"Image prompt to generate."`
	Version    string `json:"version,omitempty" jsonschema:"Optional image version selector. Omit for the maintainer default (normally Image 2.0); Image 2.5 requests must pass exactly 2.5."`
	Size       string `json:"size,omitempty" jsonschema:"Image size, defaults to 1024x1024."`
	OutputDir  string `json:"output_dir,omitempty" jsonschema:"Optional absolute directory to save the PNG."`
	OutputName string `json:"output_name,omitempty" jsonschema:"Optional PNG file name. Defaults to image2-{timestamp}.png."`
}

type editParams struct {
	Prompt     string   `json:"prompt" jsonschema:"Image prompt for the edit."`
	Version    string   `json:"version,omitempty" jsonschema:"Optional image version selector. Omit for the maintainer default (normally Image 2.0); Image 2.5 requests must pass exactly 2.5."`
	ImagePaths []string `json:"image_paths" jsonschema:"Absolute paths to source images, preserved in request order. At least one required."`
	Size       string   `json:"size,omitempty" jsonschema:"Image size, defaults to 1024x1024."`
	Quality    string   `json:"quality,omitempty" jsonschema:"Image quality, defaults to auto."`
	OutputDir  string   `json:"output_dir,omitempty" jsonschema:"Optional absolute directory to save the PNG."`
	OutputName string   `json:"output_name,omitempty" jsonschema:"Optional PNG file name. Defaults to image2-{timestamp}.png."`
	MaskPath   string   `json:"mask_path,omitempty" jsonschema:"Optional absolute path to a mask PNG."`
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
		Instructions: "Natural-language image requests such as \"帮我生成一张图\" call generate_image. The default is Image2 (Image 2.0), model: \"image2\". Only explicit 使用 Gemini 生图 / 香蕉生图 / banana 生图 requests select model: \"gemini\" (Gemini 3.1 Flash Image). User phrases \"使用 image2\" or Image2 select model: \"image2\" (Image 2.0), and Image2.5 / \"用 2.5 生图\" select model: \"image2.5\" (Image 2.5). For an existing image, photo, attachment or reference image, call edit_image directly with the same model selection. Masks are supported by Image2 only. Do not use Computer Use, browser navigation, screenshots, or generic file tools for the transformation. Preserve the user's task details, subject, style, pose, and composition. Pass all image paths in order; ~ paths are supported. Gemini uses aspect_ratio and image_size 1K/2K/4K. Image2 uses size and optional edit quality/mask_path. Legacy generate_image2/edit_image2 always use Image2; call edit_image2 only for an explicit Image2 compatibility request. Image 2.5 requests must pass version: \"2.5\" when using legacy tools. OPENAI_IMAGE_MODEL only controls the legacy Image2 default. Image2 and Gemini have independent image keys; never reuse another service key or silently switch models after an error. Do not automatically repeat failed image calls. Do not ask the user for a Base URL, model ID, endpoint, Go, Git, or admin permission. Tools save PNG images and return their local paths.",
	})

	mcp.AddTool(server, &mcp.Tool{
		Name:        "generate_image2",
		Description: "Legacy Image2-only PNG generation. Use generate_image for general requests (default Image2). This compatibility tool uses Image 2.0 unless OPENAI_IMAGE_MODEL is set; Image 2.5 requests must pass version: \"2.5\".",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, params generateParams) (*mcp.CallToolResult, image2.GenerateResult, error) {
		client, err := image2.NewFromEnv(outputDir)
		if err != nil {
			return nil, image2.GenerateResult{}, err
		}
		result, err := client.Generate(ctx, image2.GenerateRequest{
			Prompt:     params.Prompt,
			Version:    params.Version,
			Size:       params.Size,
			OutputDir:  params.OutputDir,
			OutputName: params.OutputName,
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
		Description: "Legacy Image2-only reference editing with optional mask. Use edit_image for general reference editing (default Image2). For an explicit Image2 compatibility request, call edit_image2 directly. Preserve the user's task details and source path order; ~ paths are supported. Do not use Computer Use. Omit version for legacy Image 2.0 default; Image 2.5 requires version: \"2.5\".",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, params editParams) (*mcp.CallToolResult, image2.EditResult, error) {
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
