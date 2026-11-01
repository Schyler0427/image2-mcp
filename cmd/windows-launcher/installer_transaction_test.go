package main

import (
	"context"
	"errors"
	"testing"
)

func TestInstallerTransactionCanceledBeforeResumeDoesNotMutate(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	resumed, waited, aborted := false, false, false
	err := runInstallerTransaction(ctx, func() error {
		resumed = true
		return nil
	}, func() error {
		waited = true
		return nil
	}, func() { aborted = true })
	if !errors.Is(err, context.Canceled) || resumed || !waited || !aborted {
		t.Fatalf("canceled transaction = %v, resumed=%t, waited=%t, aborted=%t", err, resumed, waited, aborted)
	}
}

func TestInstallerTransactionCancellationWaitsForRollback(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	active := "old"
	aborted := false
	failure := errors.New("installation failed and restored previous installation")
	err := runInstallerTransaction(ctx, func() error {
		active = "new"
		cancel()
		return nil
	}, func() error {
		if aborted {
			t.Fatal("cancellation killed transaction before rollback")
		}
		active = "old"
		return failure
	}, func() { aborted = true })
	if !errors.Is(err, failure) || active != "old" || aborted {
		t.Fatalf("transaction after rollback = %v, active=%q, aborted=%t", err, active, aborted)
	}
}

func TestInstallerTransactionCancellationWaitsForSuccessfulCommit(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	committed, aborted := false, false
	err := runInstallerTransaction(ctx, func() error {
		cancel()
		return nil
	}, func() error {
		committed = true
		return nil
	}, func() { aborted = true })
	if err != nil || !committed || aborted {
		t.Fatalf("transaction after commit = %v, committed=%t, aborted=%t", err, committed, aborted)
	}
}

func TestInstallerTransactionResumeFailureAbortsSuspendedProcess(t *testing.T) {
	failure := errors.New("resume failed")
	waited, aborted := false, false
	err := runInstallerTransaction(context.Background(), func() error { return failure }, func() error {
		waited = true
		return nil
	}, func() { aborted = true })
	if !errors.Is(err, failure) || !waited || !aborted {
		t.Fatalf("failed resume = %v, waited=%t, aborted=%t", err, waited, aborted)
	}
}
