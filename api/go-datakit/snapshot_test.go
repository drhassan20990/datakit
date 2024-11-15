package datakit

import (
	"log"
	"testing"

	"context"
)

func TestSnapshot(t *testing.T) {
	ctx := context.Background()
	log.Println("Testing the snapshot interface")

	client, err := dial(ctx)
	if err != nil {
		t.Fatalf("Failed to connect to db: %v", err)
	}

	trans, err := NewTransaction(ctx, client, "master")

	if err != nil {
		t.Fatalf("NewTransaction failed: %v", err)
	}
	path := []string{"snapshot", "test", "time"}
	expected := "hello!"
	err = trans.Write(ctx, path, expected)
	if err != nil {
		t.Fatalf("Transaction.Write failed: %v", err)
	}
	err = trans.Commit(ctx, "Snapshot test")
	if err != nil {
		t.Fatalf("Transaction.Commit failed: %v", err)
	}
	sha, err := Head(ctx, client, "master")
	if err != nil {
		t.Fatalf("Failed to discover the HEAD of master: %v", err)
	}
	snap := NewSnapshot(ctx, client, COMMIT, sha)
	actual, err := snap.Read(ctx, path)
	if err != nil {
		t.Fatalf("Failed to read path %v from snapshot %v: %v", path, sha, err)
	}
	if expected != actual {
		t.Fatalf("Value in snapshot (%v) doesn't match the value we wrote (%v)", actual, expected)
	}
	testpath := []string{"snapshot", "test"}
	list, err := snap.List(ctx, testpath)
	if err != nil {
		t.Fatalf("Failed to list path %v from snapshot %v: %v", testpath, sha, err)
	}
	if len(list) != 1 && list[0] != "time" {
		t.Fatalf("Value in snapshot (%v) doesn't match the value we wrote (%v)", actual, expected)
	}
}
