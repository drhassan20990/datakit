package datakit

import (
	"log"
	"testing"

	"context"
)

func TestTransaction(t *testing.T) {
	ctx := context.Background()
	log.Println("Testing the transaction interface")

	client, err := dial(ctx)
	if err != nil {
		t.Fatalf("Failed to connect to db: %v", err)
	}
	trans, err := NewTransaction(ctx, client, "master")

	if err != nil {
		t.Fatalf("NewTransaction failed: %v", err)
	}
	err = trans.Write(ctx, []string{"a", "b", "c"}, "hello!")
	if err != nil {
		t.Fatalf("Transaction.Write failed: %v", err)
	}
	err = trans.Commit(ctx, "Test transaction")
	if err != nil {
		t.Fatalf("Transaction.Commit failed: %v", err)
	}
}
