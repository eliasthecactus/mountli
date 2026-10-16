package mountli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/config/configmap"
	"github.com/rclone/rclone/fs/config/obscure"
	"github.com/rclone/rclone/fs/operations"
)

func decodeTestEnvelope(t *testing.T, raw string) envelope {
	t.Helper()
	var result envelope
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatalf("invalid bridge JSON %q: %v", raw, err)
	}
	if result.SchemaVersion != schemaVersion {
		t.Fatalf("schema version = %d", result.SchemaVersion)
	}
	return result
}

func requireSuccess(t *testing.T, raw string) envelope {
	t.Helper()
	result := decodeTestEnvelope(t, raw)
	if result.Error != nil {
		t.Fatalf("bridge error: %+v", *result.Error)
	}
	return result
}

func TestProviderCatalogContainsStaticBackends(t *testing.T) {
	result := requireSuccess(t, ProviderCatalog())
	encoded, err := json.Marshal(result.Data)
	if err != nil {
		t.Fatal(err)
	}
	catalog := string(encoded)
	for _, backend := range []string{`"name":"crypt"`, `"name":"memory"`, `"name":"s3"`, `"name":"webdav"`, `"name":"sftp"`} {
		if !strings.Contains(catalog, backend) {
			t.Errorf("catalog does not contain %s", backend)
		}
	}
}

func TestValidateConfigurationUsesUncommittedOptions(t *testing.T) {
	Shutdown()
	defer Shutdown()
	result := requireSuccess(t, ValidateConfiguration("memory", `{}`, ""))
	encoded, _ := json.Marshal(result.Data)
	if !strings.Contains(string(encoded), `"valid":true`) {
		t.Fatalf("unexpected validation result: %s", encoded)
	}
}

func TestConfigurationEditPreservesWithoutExposingPassword(t *testing.T) {
	Shutdown()
	defer Shutdown()
	storedPassword, err := obscure.Obscure("existing-password")
	if err != nil {
		t.Fatal(err)
	}
	options, err := json.Marshal(map[string]string{
		"host": "existing.example",
		"user": "alice",
		"pass": storedPassword,
	})
	if err != nil {
		t.Fatal(err)
	}
	raw := StartConfigurationWithOptions("edit-sftp", "sftp", string(options), false)
	sawPasswordQuestion := false
	for range 100 {
		result := requireSuccess(t, raw)
		encoded, marshalErr := json.Marshal(result.Data)
		if marshalErr != nil {
			t.Fatal(marshalErr)
		}
		var step struct {
			SessionID string            `json:"sessionID"`
			Status    string            `json:"status"`
			Options   map[string]string `json:"options"`
			Option    struct {
				Name       string `json:"Name"`
				DefaultStr string `json:"DefaultStr"`
			} `json:"option"`
		}
		if err := json.Unmarshal(encoded, &step); err != nil {
			t.Fatal(err)
		}
		if step.Status == "complete" {
			if _, found := step.Options["type"]; found {
				t.Fatalf("backend type leaked into remote options: %s", encoded)
			}
			if !sawPasswordQuestion || step.Options["pass"] != storedPassword {
				t.Fatalf("password was not preserved: %s", encoded)
			}
			return
		}
		if strings.Contains(string(encoded), storedPassword) {
			t.Fatal("configuration question exposed an obscured password")
		}
		if step.Option.Name == "host" && step.Option.DefaultStr != "existing.example" {
			t.Fatalf("existing host was not the default: %s", encoded)
		}
		if step.Option.Name == "pass" {
			sawPasswordQuestion = true
			if step.Option.DefaultStr != "" {
				t.Fatal("password question must not expose an existing secret")
			}
		}
		raw = ContinueConfiguration(step.SessionID, step.Option.DefaultStr)
	}
	t.Fatal("configuration did not complete")
}

func TestMemoryCryptRoundTrip(t *testing.T) {
	Shutdown()
	password, err := obscure.Obscure("a long test passphrase that is not logged")
	if err != nil {
		t.Fatal(err)
	}
	password2, err := obscure.Obscure("independent test salt")
	if err != nil {
		t.Fatal(err)
	}
	vault := vaultPayload{
		SchemaVersion: schemaVersion,
		Remotes: []remotePayload{
			{EngineName: "base-test", BackendType: "memory", Options: map[string]string{}},
			{EngineName: "crypt-test", BackendType: "crypt", Options: map[string]string{
				"remote": "base-test:encrypted", "filename_encryption": "standard",
				"directory_name_encryption": "true", "password": password, "password2": password2,
			}},
		},
	}
	encodedVault, err := json.Marshal(vault)
	if err != nil {
		t.Fatal(err)
	}
	if err := LoadVault(string(encodedVault)); err != nil {
		t.Fatal(err)
	}

	temp := t.TempDir()
	source := filepath.Join(temp, "source.txt")
	const contents = "mountli crypt round trip"
	if err := os.WriteFile(source, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	requireSuccess(t, MakeDirectory("mkdir", "crypt-test", "docs"))
	upload := requireSuccess(t, Upload("upload", "crypt-test", "docs/hello.txt", source, ""))
	uploadJSON, _ := json.Marshal(upload.Data)
	if !strings.Contains(string(uploadJSON), "hello.txt") {
		t.Fatalf("unexpected upload result: %s", uploadJSON)
	}

	listing := requireSuccess(t, List("crypt-test", "docs", "", 500))
	listingJSON, _ := json.Marshal(listing.Data)
	if !strings.Contains(string(listingJSON), "hello.txt") {
		t.Fatalf("unexpected listing: %s", listingJSON)
	}

	partial := filepath.Join(temp, "partial.txt")
	requireSuccess(t, Download("download", "crypt-test", "docs/hello.txt", "", partial, 8, 5))
	partialData, err := os.ReadFile(partial)
	if err != nil {
		t.Fatal(err)
	}
	if len(partialData) != 13 || string(partialData[8:]) != contents[8:13] {
		t.Fatalf("partial download length/content = %d/%q, want 13/%q", len(partialData), partialData[8:], contents[8:13])
	}
	for index, value := range partialData[:8] {
		if value != 0 {
			t.Fatalf("partial download byte %d = %d, want sparse zero prefix", index, value)
		}
	}

	requireSuccess(t, Move("move", "crypt-test", "docs/hello.txt", "", "docs/renamed.txt", "", ""))
	full := filepath.Join(temp, "full.txt")
	requireSuccess(t, Download("download-full", "crypt-test", "docs/renamed.txt", "", full, 0, 0))
	fullData, err := os.ReadFile(full)
	if err != nil {
		t.Fatal(err)
	}
	if string(fullData) != contents {
		t.Fatalf("full download = %q", fullData)
	}
	requireSuccess(t, Delete("delete", "crypt-test", "docs/renamed.txt", "", ""))

	baseListing := requireSuccess(t, List("base-test", "encrypted", "", 500))
	baseJSON, _ := json.Marshal(baseListing.Data)
	if strings.Contains(string(baseJSON), "hello.txt") || strings.Contains(string(baseJSON), contents) {
		t.Fatalf("plaintext leaked into base listing: %s", baseJSON)
	}
}

func TestPageTokenExpiresAfterDirectoryChange(t *testing.T) {
	Shutdown()
	defer Shutdown()
	vault := `{"schemaVersion":1,"revision":0,"remotes":[{"engineName":"page-test","backendType":"memory","options":{}}]}`
	if err := LoadVault(vault); err != nil {
		t.Fatal(err)
	}
	requireSuccess(t, MakeDirectory("page-bucket", "page-test", "bucket"))
	temp := t.TempDir()
	for index := range 2 {
		path := filepath.Join(temp, string(rune('a'+index)))
		if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		requireSuccess(t, Upload(string(rune('a'+index)), "page-test", "bucket/"+string(rune('a'+index)), path, ""))
	}
	first := requireSuccess(t, List("page-test", "bucket", "", 1))
	firstJSON, _ := json.Marshal(first.Data)
	var page struct {
		NextPageToken string `json:"nextPageToken"`
	}
	if err := json.Unmarshal(firstJSON, &page); err != nil || page.NextPageToken == "" {
		t.Fatalf("missing page token: %s (%v)", firstJSON, err)
	}
	f, err := openRemote(context.Background(), "page-test", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := operations.RcatSize(
		context.Background(), f, "bucket/c", io.NopCloser(strings.NewReader("x")), 1, time.Now(), nil,
	); err != nil {
		t.Fatal(err)
	}
	expired := decodeTestEnvelope(t, List("page-test", "bucket", page.NextPageToken, 1))
	if expired.Error == nil || expired.Error.Kind != "conflict" {
		t.Fatalf("expired page error = %+v", expired.Error)
	}
}

func TestLocalBackendPreservesAbsoluteRoot(t *testing.T) {
	Shutdown()
	defer Shutdown()
	vault := `{"schemaVersion":1,"revision":0,"remotes":[{"engineName":"local-test","backendType":"local","options":{}}]}`
	if err := LoadVault(vault); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "inside.txt"), []byte("local"), 0o600); err != nil {
		t.Fatal(err)
	}
	listing := requireSuccess(t, List("local-test", root, "", 500))
	encoded, err := json.Marshal(listing.Data)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), "inside.txt") {
		t.Fatalf("absolute local root was not listed: %s", encoded)
	}
}

func TestChangePathsRetainConfiguredRoot(t *testing.T) {
	Shutdown()
	defer Shutdown()
	vault := `{"schemaVersion":1,"revision":1,"remotes":[{"engineName":"memory-test","backendType":"memory","options":{}},{"engineName":"local-test","backendType":"local","options":{}}]}`
	if err := LoadVault(vault); err != nil {
		t.Fatal(err)
	}
	if got := pathWithinRoot("memory-test", "mounted/root", "child.txt"); got != "mounted/root/child.txt" {
		t.Fatalf("unexpected remote change path %q", got)
	}
	if got := pathWithinRoot("local-test", "/Users/example/mounted", "child.txt"); got != "Users/example/mounted/child.txt" {
		t.Fatalf("unexpected local change path %q", got)
	}
}

func TestCancelledConfigurationReleasesGlobalSession(t *testing.T) {
	Shutdown()
	defer Shutdown()
	first := requireSuccess(t, StartConfiguration("cancel-test", "sftp"))
	encoded, err := json.Marshal(first.Data)
	if err != nil {
		t.Fatal(err)
	}
	var step struct {
		SessionID string `json:"sessionID"`
		Status    string `json:"status"`
	}
	if err := json.Unmarshal(encoded, &step); err != nil {
		t.Fatal(err)
	}
	if step.Status != "question" || step.SessionID == "" {
		t.Fatalf("configuration did not start: %s", encoded)
	}
	CancelConfiguration(step.SessionID)
	requireSuccess(t, StartConfiguration("next-test", "memory"))
}

func TestConfigurationAlwaysObscuresNonEmptyBase64URLPassword(t *testing.T) {
	Shutdown()
	defer Shutdown()
	const answer = "MDEyMzQ1Njc4OWFiY2RlZg"
	_, initialCancel := context.WithCancel(baseContext)
	session := &configurationSession{
		ID: "base64-password", EngineName: "test", Values: configmap.Simple{},
		State: "accept-password", Option: &fs.Option{Name: "password2", IsPassword: true},
		Cancel: initialCancel,
		Backend: &fs.RegInfo{
			Name: "test",
			Config: func(_ context.Context, _ string, mapper configmap.Mapper, input fs.ConfigIn) (*fs.ConfigOut, error) {
				mapper.Set("password2", input.Result)
				return nil, nil
			},
		},
	}
	runtimeState.Lock()
	runtimeState.session = session
	runtimeState.Unlock()
	result := requireSuccess(t, ContinueConfiguration(session.ID, answer))
	encoded, err := json.Marshal(result.Data)
	if err != nil {
		t.Fatal(err)
	}
	var completed struct {
		Options map[string]string `json:"options"`
	}
	if err := json.Unmarshal(encoded, &completed); err != nil {
		t.Fatal(err)
	}
	stored := completed.Options["password2"]
	if stored == "" || stored == answer {
		t.Fatalf("password answer was not obscured: %q", stored)
	}
	revealed, err := obscure.Reveal(stored)
	if err != nil {
		t.Fatal(err)
	}
	if revealed != answer {
		t.Fatalf("revealed password = %q, want %q", revealed, answer)
	}
}

func TestUploadCreateRejectsDestinationCollision(t *testing.T) {
	Shutdown()
	defer Shutdown()
	if err := LoadVault(`{"schemaVersion":1,"revision":0,"remotes":[{"engineName":"collision-test","backendType":"memory","options":{}}]}`); err != nil {
		t.Fatal(err)
	}
	temp := t.TempDir()
	first := filepath.Join(temp, "first")
	second := filepath.Join(temp, "second")
	if err := os.WriteFile(first, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(second, []byte("replacement"), 0o600); err != nil {
		t.Fatal(err)
	}
	requireSuccess(t, MakeDirectory("collision-bucket", "collision-test", "collision-bucket"))
	requireSuccess(t, Upload("collision-first", "collision-test", "collision-bucket/same.txt", first, ""))
	collision := decodeTestEnvelope(t, Upload("collision-second", "collision-test", "collision-bucket/same.txt", second, ""))
	if collision.Error == nil || collision.Error.Kind != "alreadyExists" {
		t.Fatalf("collision error = %+v", collision.Error)
	}
	destination := filepath.Join(temp, "download")
	requireSuccess(t, Download("collision-download", "collision-test", "collision-bucket/same.txt", "", destination, 0, 0))
	contents, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != "original" {
		t.Fatalf("destination was replaced after collision: %q", contents)
	}
}

func TestMakeDirectoryRejectsDestinationCollision(t *testing.T) {
	Shutdown()
	defer Shutdown()
	if err := LoadVault(`{"schemaVersion":1,"revision":0,"remotes":[{"engineName":"mkdir-collision","backendType":"memory","options":{}}]}`); err != nil {
		t.Fatal(err)
	}
	requireSuccess(t, MakeDirectory("mkdir-first", "mkdir-collision", "same"))
	collision := decodeTestEnvelope(t, MakeDirectory("mkdir-second", "mkdir-collision", "same"))
	if collision.Error == nil || collision.Error.Kind != "alreadyExists" {
		t.Fatalf("directory collision error = %+v", collision.Error)
	}
}

func TestDeleteRecursivelyPurgesDirectory(t *testing.T) {
	Shutdown()
	defer Shutdown()
	if err := LoadVault(`{"schemaVersion":1,"revision":0,"remotes":[{"engineName":"delete-test","backendType":"memory","options":{}}]}`); err != nil {
		t.Fatal(err)
	}
	requireSuccess(t, MakeDirectory("delete-mkdir-parent", "delete-test", "parent"))
	requireSuccess(t, MakeDirectory("delete-mkdir-child", "delete-test", "parent/child"))
	source := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(source, []byte("nested"), 0o600); err != nil {
		t.Fatal(err)
	}
	requireSuccess(t, Upload("delete-upload", "delete-test", "parent/child/file.txt", source, ""))
	requireSuccess(t, Delete("delete-recursive", "delete-test", "parent", "", ""))
	missing := decodeTestEnvelope(t, Stat("delete-test", "parent/child/file.txt", ""))
	if missing.Error == nil || missing.Error.Kind != "notFound" {
		t.Fatalf("deleted descendant stat error = %+v", missing.Error)
	}
}

func TestCancelConfigurationInterruptsActiveStep(t *testing.T) {
	Shutdown()
	defer Shutdown()
	entered := make(chan struct{})
	_, initialCancel := context.WithCancel(baseContext)
	session := &configurationSession{
		ID: "blocking-config", EngineName: "test", Values: configmap.Simple{},
		State: "blocking", Cancel: initialCancel,
		Backend: &fs.RegInfo{
			Name: "test",
			Config: func(ctx context.Context, _ string, _ configmap.Mapper, _ fs.ConfigIn) (*fs.ConfigOut, error) {
				close(entered)
				<-ctx.Done()
				return nil, ctx.Err()
			},
		},
	}
	runtimeState.Lock()
	runtimeState.session = session
	runtimeState.Unlock()
	result := make(chan envelope, 1)
	go func() {
		result <- decodeTestEnvelope(t, ContinueConfiguration(session.ID, "continue"))
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("configuration step did not start")
	}
	CancelConfiguration(session.ID)
	select {
	case response := <-result:
		if response.Error == nil || response.Error.Kind != "cancelled" {
			t.Fatalf("cancellation error = %+v", response.Error)
		}
	case <-time.After(time.Second):
		t.Fatal("configuration cancellation was blocked by the session lock")
	}
}

func TestImportConfigReturnsResourceRequirements(t *testing.T) {
	Shutdown()
	defer Shutdown()
	path := filepath.Join(t.TempDir(), "rclone.conf")
	configText := `[files]
type = sftp
host = example.invalid
key_file = /machine/id_ed25519
known_hosts_file = /machine/known_hosts
`
	if err := os.WriteFile(path, []byte(configText), 0o600); err != nil {
		t.Fatal(err)
	}
	result := requireSuccess(t, ImportConfig(path, ""))
	encoded, err := json.Marshal(result.Data)
	if err != nil {
		t.Fatal(err)
	}
	var imported struct {
		ResourceRequirements []resourceRequirement `json:"resourceRequirements"`
	}
	if err := json.Unmarshal(encoded, &imported); err != nil {
		t.Fatal(err)
	}
	if len(imported.ResourceRequirements) != 2 {
		t.Fatalf("resource requirements = %+v", imported.ResourceRequirements)
	}
	kinds := map[string]string{}
	for _, requirement := range imported.ResourceRequirements {
		kinds[requirement.OptionName] = requirement.Kind
	}
	if kinds["key_file"] != "sshPrivateKey" || kinds["known_hosts_file"] != "knownHosts" {
		t.Fatalf("resource requirement kinds = %+v", kinds)
	}
}

func TestEffectiveReadOnlyTraversesOverlayDependencies(t *testing.T) {
	Shutdown()
	defer Shutdown()
	vault := vaultPayload{
		SchemaVersion: schemaVersion,
		Remotes: []remotePayload{
			{EngineName: "web", BackendType: "http", Options: map[string]string{"url": "https://example.invalid"}},
			{EngineName: "encrypted", BackendType: "crypt", Options: map[string]string{"remote": "web:files"}},
			{EngineName: "combined", BackendType: "combine", Options: map[string]string{"upstreams": "public=web:pub"}},
			{EngineName: "archives", BackendType: "archive", Options: map[string]string{"remote": "web:archives"}},
		},
	}
	encoded, err := json.Marshal(vault)
	if err != nil {
		t.Fatal(err)
	}
	if err := LoadVault(string(encoded)); err != nil {
		t.Fatal(err)
	}
	for _, remote := range []string{"web", "encrypted", "combined", "archives"} {
		if !effectiveReadOnly(remote, make(map[string]bool)) {
			t.Errorf("%s was not effectively read-only", remote)
		}
	}
}

func TestRememberListedDirectoryTracksNestedWatcherPaths(t *testing.T) {
	Shutdown()
	defer Shutdown()
	runtimeState.Lock()
	runtimeState.watchers["watch"] = watcher{
		cancel: func() {}, remote: "memory-test", root: "mounted/root",
		directories: map[string]string{"": "root-generation"},
	}
	runtimeState.Unlock()
	rememberListedDirectory("memory-test", "mounted/root/nested")
	runtimeState.RLock()
	_, found := runtimeState.watchers["watch"].directories["nested"]
	runtimeState.RUnlock()
	if !found {
		t.Fatal("nested browsed directory was not added to watcher polling")
	}
}

func TestDeadlineMapsToRetryableUnreachable(t *testing.T) {
	mapped := mapError(context.DeadlineExceeded)
	if mapped.Kind != "unreachable" || !mapped.Retryable {
		t.Fatalf("deadline mapping = %+v", mapped)
	}
}

type identifiedTestEntry struct {
	remote string
	id     string
}

func (entry identifiedTestEntry) Fs() fs.Info                       { return nil }
func (entry identifiedTestEntry) String() string                    { return entry.remote }
func (entry identifiedTestEntry) Remote() string                    { return entry.remote }
func (entry identifiedTestEntry) ModTime(context.Context) time.Time { return time.Time{} }
func (entry identifiedTestEntry) Size() int64                       { return 0 }
func (entry identifiedTestEntry) ID() string                        { return entry.id }

func TestExactIDResolutionTakesPrecedenceOverStaleName(t *testing.T) {
	entries := fs.DirEntries{
		identifiedTestEntry{remote: "folder/old-name.txt", id: "wrong"},
		identifiedTestEntry{remote: "folder/new-name.txt", id: "selected"},
	}
	entry, err := findListedEntry(entries, "folder/old-name.txt", "old-name.txt", "selected")
	if err != nil {
		t.Fatal(err)
	}
	if entry.Remote() != "folder/new-name.txt" {
		t.Fatalf("resolved path = %q", entry.Remote())
	}
}

func TestShortDownloadStageIsRejectedAsRetryable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "short-download")
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	written, err := writeDownloadStage(file, strings.NewReader("abc"), "short", 4, 5)
	if err == nil || written != 3 {
		t.Fatalf("short download result = %d, %v", written, err)
	}
	mapped := mapError(err)
	if mapped.Kind != "unreachable" || !mapped.Retryable {
		t.Fatalf("short download mapping = %+v", mapped)
	}
}

func TestSparseDownloadWritesBoundedMemoryAndPreservesLogicalContent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sparse-download")
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	const total = int64(10) << 30
	start := make([]byte, 256*1024)
	end := make([]byte, 256*1024)
	for index := range start {
		start[index] = byte(index)
		end[index] = byte(index ^ 0xA5)
	}
	source := io.MultiReader(
		strings.NewReader(string(start)),
		io.LimitReader(zeroReader{}, total-int64(len(start)+len(end))),
		strings.NewReader(string(end)),
	)
	runtime.GC()
	var before runtime.MemStats
	runtime.ReadMemStats(&before)
	written, err := writeDownloadStage(file, source, "ten-gib-sparse", 0, total)
	if err != nil {
		t.Fatal(err)
	}
	runtime.GC()
	var after runtime.MemStats
	runtime.ReadMemStats(&after)
	if written != total {
		t.Fatalf("written = %d", written)
	}
	if growth := int64(after.Sys) - int64(before.Sys); growth >= 32<<20 {
		t.Fatalf("runtime memory grew by %d bytes", growth)
	}
	info, err := file.Stat()
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() != total {
		t.Fatalf("logical size = %d", info.Size())
	}
	actualStart := make([]byte, len(start))
	if _, err := file.ReadAt(actualStart, 0); err != nil {
		t.Fatal(err)
	}
	actualEnd := make([]byte, len(end))
	if _, err := file.ReadAt(actualEnd, total-int64(len(end))); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(actualStart, start) || !bytes.Equal(actualEnd, end) {
		t.Fatal("sparse download content mismatch")
	}
	if allocatedBlocks, ok := allocatedFileBlocks(path); ok && allocatedBlocks*512 >= 32<<20 {
		t.Fatalf("sparse file allocated %d bytes", allocatedBlocks*512)
	}
}

func TestMutationFaultTransitionsAreIdempotent(t *testing.T) {
	Shutdown()
	defer Shutdown()
	root := t.TempDir()
	vault, err := json.Marshal(vaultPayload{
		SchemaVersion: schemaVersion,
		Revision:      1,
		Remotes: []remotePayload{{
			EngineName:  "fault-local",
			BackendType: "local",
			Options:     map[string]string{},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := LoadVault(string(vault)); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(t.TempDir(), "source.bin")
	contents := []byte("idempotent payload")
	if err := os.WriteFile(source, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(root, "destination.bin")

	for _, point := range []string{
		"upload.before-stage",
		"upload.after-stage",
		"upload.before-promote",
		"upload.after-promote",
	} {
		t.Run(point, func(t *testing.T) {
			_ = os.Remove(destination)
			cleanupLocalUploadStages(t, root)
			failed := false
			mutationFaultHook = func(actual string) error {
				if !failed && actual == point {
					failed = true
					return errors.New("injected " + point)
				}
				return nil
			}
			first := decodeTestEnvelope(t, Upload("upload-"+point, "fault-local", destination, source, ""))
			if first.Error == nil {
				t.Fatalf("%s was not injected", point)
			}
			mutationFaultHook = nil
			requireSuccess(t, Upload("upload-retry-"+point, "fault-local", destination, source, ""))
			got, err := os.ReadFile(destination)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(got, contents) {
				t.Fatalf("%s left partial destination %q", point, got)
			}
			cleanupLocalUploadStages(t, root)
		})
	}

	if err := os.WriteFile(destination, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	mutationFaultHook = func(point string) error {
		if point == "delete.after-remote" {
			return errors.New("injected delete completion loss")
		}
		return nil
	}
	firstDelete := decodeTestEnvelope(t, Delete("delete-first", "fault-local", destination, "", ""))
	if firstDelete.Error == nil {
		t.Fatal("delete completion loss was not injected")
	}
	mutationFaultHook = nil
	requireSuccess(t, Delete("delete-retry", "fault-local", destination, "", ""))
	if _, err := os.Stat(destination); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("delete retry left destination: %v", err)
	}
}

func TestCancelInterruptsTransferWithinTwoSeconds(t *testing.T) {
	Shutdown()
	defer Shutdown()
	reader, writer := io.Pipe()
	destination := filepath.Join(t.TempDir(), "cancelled")
	file, err := os.OpenFile(destination, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	ctx, done, err := operationContext("cancel-latency")
	if err != nil {
		t.Fatal(err)
	}
	defer done()
	// A real provider body aborts a blocked read when its request context is
	// cancelled; without this the copy loop can already be parked in the pipe
	// read and observe a clean EOF instead of the cancellation.
	stopAbort := context.AfterFunc(ctx, func() { _ = reader.CloseWithError(ctx.Err()) })
	defer stopAbort()
	defer writer.Close()
	result := make(chan error, 1)
	go func() {
		_, copyErr := writeDownloadStage(file, &contextReader{ctx: ctx, reader: reader}, "cancel-latency", 0, -1)
		result <- copyErr
	}()
	if _, err := writer.Write(make([]byte, 256*1024)); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	Cancel("cancel-latency")
	select {
	case copyErr := <-result:
		if copyErr == nil {
			t.Fatal("cancelled transfer unexpectedly succeeded")
		}
		if elapsed := time.Since(started); elapsed >= 2*time.Second {
			t.Fatalf("cancel took %s", elapsed)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancel did not interrupt transfer within two seconds")
	}
}

type zeroReader struct{}

func (zeroReader) Read(destination []byte) (int, error) {
	clear(destination)
	return len(destination), nil
}

func TestTenThousandEntryListingUsesBoundedPagesAndMemory(t *testing.T) {
	Shutdown()
	defer Shutdown()
	root := t.TempDir()
	for index := range 10_000 {
		name := filepath.Join(root, fmt.Sprintf("entry-%05d", index))
		if err := os.WriteFile(name, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	vault, err := json.Marshal(vaultPayload{
		SchemaVersion: schemaVersion,
		Revision:      1,
		Remotes: []remotePayload{{
			EngineName:  "scale-local",
			BackendType: "local",
			Options:     map[string]string{},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := LoadVault(string(vault)); err != nil {
		t.Fatal(err)
	}
	runtime.GC()
	var before runtime.MemStats
	runtime.ReadMemStats(&before)
	token := ""
	count := 0
	pages := 0
	for {
		raw := requireSuccess(t, List("scale-local", root, token, 500))
		encoded, err := json.Marshal(raw.Data)
		if err != nil {
			t.Fatal(err)
		}
		var page struct {
			Items         []json.RawMessage `json:"items"`
			NextPageToken string            `json:"nextPageToken"`
		}
		if err := json.Unmarshal(encoded, &page); err != nil {
			t.Fatal(err)
		}
		if len(page.Items) == 0 || len(page.Items) > 500 {
			t.Fatalf("page size = %d", len(page.Items))
		}
		count += len(page.Items)
		pages++
		token = page.NextPageToken
		if token == "" {
			break
		}
	}
	runtime.GC()
	var after runtime.MemStats
	runtime.ReadMemStats(&after)
	if count != 10_000 || pages != 20 {
		t.Fatalf("listed %d entries in %d pages", count, pages)
	}
	if growth := int64(after.Sys) - int64(before.Sys); growth >= 100<<20 {
		t.Fatalf("runtime memory grew by %d bytes", growth)
	}
}

type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (reader *contextReader) Read(destination []byte) (int, error) {
	select {
	case <-reader.ctx.Done():
		return 0, reader.ctx.Err()
	default:
		return reader.reader.Read(destination)
	}
}

func cleanupLocalUploadStages(t *testing.T, root string) {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join(root, ".mountli-upload-*"))
	if err != nil {
		t.Fatal(err)
	}
	for _, match := range matches {
		if err := os.Remove(match); err != nil && !errors.Is(err, os.ErrNotExist) {
			t.Fatal(err)
		}
	}
}

func allocatedFileBlocks(path string) (int64, bool) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, false
	}
	type blockCounter interface {
		Blocks() int64
	}
	if blocks, ok := info.Sys().(blockCounter); ok {
		return blocks.Blocks(), true
	}
	value := reflect.ValueOf(info.Sys())
	if value.Kind() == reflect.Pointer {
		value = value.Elem()
	}
	field := value.FieldByName("Blocks")
	if !field.IsValid() {
		return 0, false
	}
	return field.Int(), true
}

type recordingMutationListener struct {
	mu        sync.Mutex
	mutations []mutation
}

func (listener *recordingMutationListener) OnMutation(raw string) string {
	var value mutation
	if err := json.Unmarshal([]byte(raw), &value); err != nil {
		return failure("internal", err.Error(), false)
	}
	listener.mu.Lock()
	listener.mutations = append(listener.mutations, value)
	listener.mu.Unlock()
	return success(map[string]any{"persisted": true})
}

func TestMemoryStorageSerializesRevisionedMutations(t *testing.T) {
	Shutdown()
	defer Shutdown()
	listener := &recordingMutationListener{}
	SetVaultMutationListener(listener)
	storage := newMemoryStorage()
	storage.revision = 41
	var group sync.WaitGroup
	group.Add(2)
	go func() {
		defer group.Done()
		storage.SetValue("remote", "token", "first")
	}()
	go func() {
		defer group.Done()
		storage.SetValue("remote", "token", "second")
	}()
	group.Wait()
	listener.mu.Lock()
	defer listener.mu.Unlock()
	if len(listener.mutations) != 2 {
		t.Fatalf("mutation count = %d", len(listener.mutations))
	}
	if listener.mutations[0].ExpectedRevision != 41 || listener.mutations[1].ExpectedRevision != 42 {
		t.Fatalf("mutation revisions = %d, %d", listener.mutations[0].ExpectedRevision, listener.mutations[1].ExpectedRevision)
	}
	if listener.mutations[0].PreviousValuePresent || !listener.mutations[1].PreviousValuePresent {
		t.Fatalf("previous value metadata = %+v", listener.mutations)
	}
	if listener.mutations[1].PreviousValue != listener.mutations[0].Value {
		t.Fatalf("previous value %q does not match first mutation %q", listener.mutations[1].PreviousValue, listener.mutations[0].Value)
	}
}
