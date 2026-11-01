package main

import "context"

// runInstallerTransaction has one cancellation boundary: the suspended child
// may be aborted before resume. Once running, its transaction must reach its
// own commit or rollback rather than being terminated in the middle of moves.
func runInstallerTransaction(ctx context.Context, resume, wait func() error, abort func()) error {
	if err := ctx.Err(); err != nil {
		abort()
		_ = wait()
		return err
	}
	if err := resume(); err != nil {
		abort()
		_ = wait()
		return err
	}
	return wait()
}
