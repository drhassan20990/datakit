package datakit

import (
	"context"
	"fmt"
	"log"
	"testing"
)

func TestConfig(t *testing.T) {
	ctx := context.Background()
	log.Println("Testing the configuration interface")

	client, err := dial(ctx)
	if err != nil {
		t.Fatalf("Failed to connect to db: %v", err)
	}
	r, err := NewRecord(ctx, client, []string{"master", "defaults"}, "defaults", "state", []string{"tests"})
	if err != nil {
		t.Fatalf("NewRecord failed: %v", err)
	}
	err = write(ctx, client, []string{"tests", "name"}, "hello")
	err = write(ctx, client, []string{"tests", "ncpu"}, "1")
	err = write(ctx, client, []string{"tests", "running"}, "true")
	r.Wait(ctx)

	nameF := r.StringField("name", "hello")
	ncpuF := r.IntField("ncpu", 1)
	runningF := r.BoolField("running", true)

	name, nameV := nameF.Get()
	ncpu, ncpuV := ncpuF.Get()
	running, runningV := runningF.Get()
	fmt.Printf("name: %s, ncpu: %d, running: %t\n", name, ncpu, running)

	if nameF.HasChanged(nameV) {
		t.Fatalf("name has unexpectedly changed")
	}
	if ncpuF.HasChanged(ncpuV) {
		t.Fatalf("ncpu has unexpectedly changed")
	}
	if runningF.HasChanged(runningV) {
		t.Fatalf("running has unexpectedly changed")
	}
	err = write(ctx, client, []string{"tests", "name"}, "there")
	if err != nil {
		t.Fatalf("failed to write new name value: %v", err)
	}
	r.Wait(ctx)
	if nameF.HasChanged(nameV) {
		name, nameV = nameF.Get()
		fmt.Printf("name has changed to %s\n", name)
	} else {
		t.Fatalf("name should have changed but hasn't")
	}
	// ncpu should not have changed
	if ncpuF.HasChanged(ncpuV) {
		ncpu, ncpuV = ncpuF.Get()
		t.Fatalf("ncpu has unexpectedly changed to %d\n", ncpu)
	}
	if runningF.HasChanged(runningV) {
		t.Fatalf("running has unexpectedly changed")
	}
	err = write(ctx, client, []string{"tests", "ncpu"}, "5")
	if err != nil {
		t.Fatalf("failed to write new ncpu value: %v", err)
	}
	r.Wait(ctx)
	if ncpuF.HasChanged(ncpuV) {
		ncpu, ncpuV = ncpuF.Get()
		fmt.Printf("ncpu has changed to %d\n", ncpu)
	}
	err = write(ctx, client, []string{"tests", "running"}, "rubbish")
	if err != nil {
		t.Fatalf("failed to write new running value: %v", err)
	}
	r.Wait(ctx)
	if runningF.HasChanged(runningV) {
		running, runningV = runningF.Get()
		fmt.Printf("running has changed to %t\n", running)
	}
	// Schema upgrade testing:
	// 1. no change to ncpus (current value is 5)
	if ncpuF.HasChanged(ncpuV) {
		ncpu, ncpuV = ncpuF.Get()
		t.Fatalf("ncpu has unexpectedly changed to %d\n", ncpu)
	}
	// 2. a no-op upgrade
	r.Upgrade(ctx, 1)
	if ncpuF.HasChanged(ncpuV) {
		t.Fatalf("ncpu has unexpectedly changed")
	}
	// 3. a real upgrade
	r.Upgrade(ctx, 2)
	if ncpuF.HasChanged(ncpuV) {
		ncpu, ncpuV = ncpuF.Get()
		fmt.Printf("ncpu has changed to %d\n", ncpu)
		if ncpu != 1 {
			t.Fatalf("Upgrade didn't set ncpu to 1\n")
		}
	}
}

func TestChangeDefaults(t *testing.T) {
	ctx := context.Background()
	log.Println("Check that defaults can be updated")

	client, err := dial(ctx)
	if err != nil {
		t.Fatalf("Failed to connect to db: %v", err)
	}
	key := "change-default-key"
	if err = rm(ctx, client, "defaults", []string{"tests", key}); err != nil {
		t.Fatalf("Failed to remove previous test state")
	}

	r, err := NewRecord(ctx, client, []string{"master", "defaults"}, "defaults", "state", []string{"tests"})
	if err != nil {
		t.Fatalf("NewRecord failed: %v", err)
	}
	r.Wait(ctx)

	nameF := r.StringField(key, "hello")
	r.Seal(ctx)

	def, err := read(ctx, client, "defaults", []string{"tests", key})
	if err != nil {
		t.Fatalf("r.StringField didn't create a defaults branch entry")
	}
	if def != "hello" {
		t.Fatalf("r.StringField should have set the default value to hello: %s", def)
	}
	name, _ := nameF.Get()
	if name != "hello" {
		t.Fatalf("r.Get after r.StringField should have read the default value of hello: %s", name)
	}

	r, err = NewRecord(ctx, client, []string{"master", "defaults"}, "defaults", "state", []string{"tests"})
	if err != nil {
		t.Fatalf("NewRecord failed: %v", err)
	}
	r.Wait(ctx)
	nameF = r.StringField(key, "there")
	r.Seal(ctx)

	def, err = read(ctx, client, "defaults", []string{"tests", key})
	if err != nil {
		t.Fatalf("r.StringField didn't create a defaults branch entry")
	}
	if def != "there" {
		t.Fatalf("r.StringField should have reset the default value to there: %s", def)
	}
	name, _ = nameF.Get()
	if name != "there" {
		t.Fatalf("r.Get after r.StringField should have read the new default value of there: %s", name)
	}
}

func write(ctx context.Context, client *Client, path []string, value string) error {
	t, err := NewTransaction(ctx, client, "master")

	if err != nil {
		return err
	}
	err = t.Write(ctx, path, value)
	if err != nil {
		return err
	}
	err = t.Commit(ctx, "Write test")
	if err != nil {
		return err
	}

	return nil
}

func rm(ctx context.Context, client *Client, branch string, path []string) error {
	t, err := NewTransaction(ctx, client, branch)

	if err != nil {
		return err
	}
	err = t.Remove(ctx, path)
	if err != nil {
		return err
	}
	err = t.Commit(ctx, "Write test")
	if err != nil {
		return err
	}

	return nil
}

func read(ctx context.Context, client *Client, branch string, path []string) (string, error) {
	sha, err := Head(ctx, client, branch)
	if err != nil {
		return "", err
	}
	snap := NewSnapshot(ctx, client, COMMIT, sha)
	return snap.Read(ctx, path)
}
