package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"

	"image2-mcp/internal/image2"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const serverVersion = "0.3.1"

type generateParams struct {
	Prompt     string `json:"prompt" jsonschema:"Image prompt to generate."`
	Version    string `json:"version,omitempty" jsonschema:"Optional image version selector: omit for Image 2.0; use 2.5 for Image 2.5."`
	Size       string `json:"size,omitempty" jsonschema:"Image size, defaults to 1024x1024."`
	OutputDir  string `json:"output_dir,omitempty" jsonschema:"Optional absolute directory to save the PNG."`
	OutputName string `json:"output_name,omitempty" jsonschema:"Optional PNG file name. Defaults to image2-{timestamp}.png."`
}

type editParams struct {
	Prompt     string   `json:"prompt" jsonschema:"Image prompt for the edit."`
	Version    string   `json:"version,omitempty" jsonschema:"Optional image version selector: omit for Image 2.0; use 2.5 for Image 2.5."`
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
	projectRoot, err := findProjectRoot()
	if err != nil {
		return err
	}
	outputDir := filepath.Join(projectRoot, "output", "imagegen")
	server := newServer(projectRoot, outputDir)
	return server.Run(context.Background(), &mcp.StdioTransport{})
}

func newServer(projectRoot, outputDir string) *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{
		Name:    "image2-mcp",
		Version: serverVersion,
	}, &mcp.ServerOptions{
		Instructions: "Natural-language image requests such as \"帮我生成一张图\" automatically call generate_image2. You may explicitly say \"使用 image2\" to use these tools. The default is Image 2.0 unless the maintainer explicitly sets OPENAI_IMAGE_MODEL to configure a different default; say \"用 2.5 生图\" or set version to 2.5 to select Image 2.5. Do not ask the user for a Base URL, model ID, endpoint, Go, Git, or admin permission. The tools generate or edit PNG files and return the local file path.",
	})

	mcp.AddTool(server, &mcp.Tool{
		Name:        "generate_image2",
		Description: "Generate one PNG image. Natural-language requests automatically use this tool; omit version for the maintainer-configured default (Image 2.0 unless OPENAI_IMAGE_MODEL is explicitly set), or set version to 2.5 for Image 2.5. Save the result locally.",
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
		Description: "Edit one or more local images with an optional mask. Omit version for the maintainer-configured default (Image 2.0 unless OPENAI_IMAGE_MODEL is explicitly set), or set version to 2.5 for Image 2.5, then save the result locally.",
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
