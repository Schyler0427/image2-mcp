package image2

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"image/gif"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const maxGIFCanvasPixels = 32_000_000

func validateGIFSize(size string, frames int) (string, error) {
	size = strings.ToLower(size)
	if size == "auto" {
		return size, nil
	}
	parts := strings.Split(size, "x")
	if len(parts) != 2 {
		return "", errors.New("GIF size must be auto or positive WIDTHxHEIGHT multiples of 16")
	}
	width, widthErr := strconv.ParseUint(parts[0], 10, 64)
	height, heightErr := strconv.ParseUint(parts[1], 10, 64)
	if widthErr != nil || heightErr != nil || width == 0 || height == 0 || width%16 != 0 || height%16 != 0 {
		return "", errors.New("GIF size must be auto or positive WIDTHxHEIGHT multiples of 16")
	}
	if frames <= 0 || width > uint64(maxGIFCanvasPixels)/uint64(frames)/height {
		return "", errors.New("GIF request exceeds 32 million cumulative canvas pixels")
	}
	return size, nil
}

// Check frame count and decoded canvas cost before gif.DecodeAll allocates frames.
func preflightGIF(data []byte) error {
	if len(data) < 13 || (string(data[:6]) != "GIF87a" && string(data[:6]) != "GIF89a") {
		return errors.New("GIF response has invalid signature or header")
	}
	width := int(binary.LittleEndian.Uint16(data[6:8]))
	height := int(binary.LittleEndian.Uint16(data[8:10]))
	if width == 0 || height == 0 {
		return errors.New("GIF response has invalid canvas dimensions")
	}
	canvasPixels := int64(width) * int64(height)
	if canvasPixels > maxGIFCanvasPixels {
		return errors.New("GIF response exceeds 32 million cumulative canvas pixels")
	}
	pos := 13
	skipColorTable := func(packed byte) error {
		if packed&0x80 == 0 {
			return nil
		}
		size := 3 * (1 << ((packed & 0x07) + 1))
		if size > len(data)-pos {
			return errors.New("GIF response has truncated color table")
		}
		pos += size
		return nil
	}
	skipBlocks := func() error {
		for {
			if pos >= len(data) {
				return errors.New("GIF response has truncated data blocks")
			}
			size := int(data[pos])
			pos++
			if size == 0 {
				return nil
			}
			if size > len(data)-pos {
				return errors.New("GIF response has truncated data blocks")
			}
			pos += size
		}
	}
	if err := skipColorTable(data[10]); err != nil {
		return err
	}
	frames := 0
	for pos < len(data) {
		marker := data[pos]
		pos++
		switch marker {
		case 0x21: // extension
			if pos >= len(data) {
				return errors.New("GIF response has truncated extension")
			}
			pos++ // extension label
			if err := skipBlocks(); err != nil {
				return err
			}
		case 0x2c: // image descriptor
			if len(data)-pos < 10 {
				return errors.New("GIF response has truncated image descriptor")
			}
			left := int(binary.LittleEndian.Uint16(data[pos : pos+2]))
			top := int(binary.LittleEndian.Uint16(data[pos+2 : pos+4]))
			frameWidth := int(binary.LittleEndian.Uint16(data[pos+4 : pos+6]))
			frameHeight := int(binary.LittleEndian.Uint16(data[pos+6 : pos+8]))
			packed := data[pos+8]
			pos += 9
			if frameWidth == 0 || frameHeight == 0 || left > width-frameWidth || top > height-frameHeight {
				return errors.New("GIF response has invalid frame dimensions")
			}
			frames++
			if frames > 64 {
				return errors.New("GIF response exceeds 64 frames")
			}
			if canvasPixels*int64(frames) > maxGIFCanvasPixels {
				return errors.New("GIF response exceeds 32 million cumulative canvas pixels")
			}
			if err := skipColorTable(packed); err != nil {
				return err
			}
			pos++ // LZW minimum code size
			if err := skipBlocks(); err != nil {
				return err
			}
		case 0x3b: // trailer
			if frames < 2 {
				return errors.New("GIF response must contain at least two frames")
			}
			return nil
		default:
			return errors.New("GIF response has invalid block marker")
		}
	}
	return errors.New("GIF response is missing trailer")
}

func saveGIF(data []byte, outputDir, outputName, model string) (GenerateResult, error) {
	if len(data) > maxImageResponseBytes {
		return GenerateResult{}, errors.New("GIF response exceeds 64 MiB")
	}
	if err := preflightGIF(data); err != nil {
		return GenerateResult{}, err
	}
	decoded, err := gif.DecodeAll(bytes.NewReader(data))
	if err != nil {
		return GenerateResult{}, errors.New("GIF response is corrupt or invalid")
	}
	if len(decoded.Image) < 2 || len(decoded.Image) > 64 {
		return GenerateResult{}, errors.New("GIF response must contain 2 to 64 frames")
	}
	durationMS := 0
	for _, delay := range decoded.Delay {
		durationMS += delay * 10
	}
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return GenerateResult{}, fmt.Errorf("create output directory: %w", err)
	}
	fileName := cleanGIFOutputName(outputName)
	if fileName == "" {
		fileName = "image2-" + time.Now().Format("20060102-150405") + ".gif"
	}
	filePath := filepath.Join(outputDir, fileName)
	if err := os.WriteFile(filePath, data, 0o644); err != nil {
		return GenerateResult{}, fmt.Errorf("write GIF: %w", err)
	}
	return GenerateResult{
		FilePath: filePath, Model: model, Size: fmt.Sprintf("%dx%d", decoded.Config.Width, decoded.Config.Height),
		OutputFormat: "gif", FrameCount: len(decoded.Image), DurationMS: &durationMS,
	}, nil
}

func cleanGIFOutputName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return ""
	}
	name = filepath.Base(name)
	name = safeNameRE.ReplaceAllString(name, "-")
	name = strings.Trim(name, ".-")
	if name == "" {
		return ""
	}
	ext := filepath.Ext(name)
	if strings.EqualFold(ext, ".png") || strings.EqualFold(ext, ".gif") {
		name = strings.TrimSuffix(name, ext)
	}
	return name + ".gif"
}
