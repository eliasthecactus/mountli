// Package mountli exposes the gomobile-safe MOUNTLI rclone bridge.
package mountli

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "github.com/rclone/rclone/backend/all"
	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/cache"
	"github.com/rclone/rclone/fs/config"
	"github.com/rclone/rclone/fs/config/configfile"
	"github.com/rclone/rclone/fs/config/configmap"
	"github.com/rclone/rclone/fs/config/obscure"
	"github.com/rclone/rclone/fs/hash"
	"github.com/rclone/rclone/fs/operations"
	"github.com/rclone/rclone/lib/oauthutil"
)

const schemaVersion = 1
const memoryConfigPath = "mountli-memory-config"

// ProgressListener receives immutable transfer counters. Implementations must return quickly.
type ProgressListener interface {
	OnProgress(operationID string, completed, total int64)
}

// VaultMutationListener durably persists one rclone config mutation.
type VaultMutationListener interface {
	OnMutation(mutationJSON string) string
}

// OAuthListener opens an authorization URL in the host application.
type OAuthListener interface {
	Open(url string) bool
}

// ChangeListener receives immutable JSON arrays of changed remote paths.
type ChangeListener interface {
	OnChange(watcherID, pathsJSON string)
}

type bridgeError struct {
	Kind      string `json:"kind"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
}

type envelope struct {
	SchemaVersion int          `json:"schemaVersion"`
	Data          any          `json:"data,omitempty"`
	Error         *bridgeError `json:"error,omitempty"`
}

type configurationSession struct {
	ID         string
	EngineName string
	Backend    *fs.RegInfo
	Values     configmap.Simple
	State      string
	Advanced   bool
	Option     *fs.Option
	Cancel     context.CancelFunc
}

type watcher struct {
	cancel      context.CancelFunc
	remote      string
	root        string
	directories map[string]string
}

type listSession struct {
	Remote     string
	Directory  string
	Generation string
	Items      []map[string]any
	ExpiresAt  time.Time
}

var runtimeState = struct {
	sync.RWMutex
	storage         *memoryStorage
	progress        ProgressListener
	vaultMutation   VaultMutationListener
	oauth           OAuthListener
	changes         ChangeListener
	operations      map[string]context.CancelFunc
	watchers        map[string]watcher
	session         *configurationSession
	listSessions    map[string]listSession
	lastMutationErr error
}{
	storage:      newMemoryStorage(),
	operations:   make(map[string]context.CancelFunc),
	watchers:     make(map[string]watcher),
	listSessions: make(map[string]listSession),
}

var configSessionMu sync.Mutex
var baseContext context.Context

// mutationFaultHook is test-only fault injection for crash/retry proofs.
// Production builds leave it nil.
var mutationFaultHook func(string) error

func injectMutationFault(point string) error {
	if mutationFaultHook == nil {
		return nil
	}
	return mutationFaultHook(point)
}

func init() {
	baseContext, _ = fs.AddConfig(context.Background())
	_ = config.SetConfigPath(memoryConfigPath)
	config.SetData(runtimeState.storage)
	oauthutil.OpenURL = func(url string) error {
		runtimeState.RLock()
		listener := runtimeState.oauth
		runtimeState.RUnlock()
		if listener == nil || !listener.Open(url) {
			return errors.New("authorization URL was not accepted by the host")
		}
		return nil
	}
}

// Version reports the pinned rclone engine version.
func Version() string { return fs.Version }

func SetProgressListener(listener ProgressListener) {
	runtimeState.Lock()
	runtimeState.progress = listener
	runtimeState.Unlock()
}

func SetVaultMutationListener(listener VaultMutationListener) {
	runtimeState.Lock()
	runtimeState.vaultMutation = listener
	runtimeState.Unlock()
}

func SetOAuthListener(listener OAuthListener) {
	runtimeState.Lock()
	runtimeState.oauth = listener
	runtimeState.Unlock()
}

func SetChangeListener(listener ChangeListener) {
	runtimeState.Lock()
	runtimeState.changes = listener
	runtimeState.Unlock()
}

// LoadVault atomically replaces the process-local rclone configuration.
func LoadVault(configJSON string) error {
	storage, err := storageFromVault(configJSON)
	if err != nil {
		return err
	}
	configSessionMu.Lock()
	defer configSessionMu.Unlock()
	runtimeState.Lock()
	runtimeState.storage = storage
	runtimeState.lastMutationErr = nil
	runtimeState.listSessions = make(map[string]listSession)
	runtimeState.Unlock()
	cache.Clear()
	if err := config.SetConfigPath(memoryConfigPath); err != nil {
		return err
	}
	config.SetData(storage)
	return nil
}

func ProviderCatalog() string {
	type provider struct {
		Name        string     `json:"name"`
		Description string     `json:"description"`
		Aliases     []string   `json:"aliases,omitempty"`
		Options     fs.Options `json:"options"`
		TestOnly    bool       `json:"testOnly"`
		Overlay     bool       `json:"overlay"`
	}
	providers := make([]provider, 0, len(fs.Registry))
	for _, info := range fs.Registry {
		if info.Hide {
			continue
		}
		overlay := map[string]bool{
			"alias": true, "archive": true, "cache": true, "chunker": true,
			"combine": true, "compress": true, "crypt": true, "hasher": true, "union": true,
		}[info.Name]
		providers = append(providers, provider{
			Name: info.Name, Description: info.Description, Aliases: info.Aliases,
			Options: info.Options, TestOnly: info.Name == "memory", Overlay: overlay,
		})
	}
	sort.Slice(providers, func(i, j int) bool { return providers[i].Name < providers[j].Name })
	return success(providers)
}

func StartConfiguration(engineName, backendType string) string {
	return StartConfigurationAdvanced(engineName, backendType, false)
}

func StartConfigurationAdvanced(engineName, backendType string, advanced bool) string {
	return startConfiguration(engineName, backendType, advanced, nil)
}

func StartConfigurationWithOptions(engineName, backendType, optionsJSON string, advanced bool) string {
	options := map[string]string{}
	if err := json.Unmarshal([]byte(optionsJSON), &options); err != nil {
		return failure("unsupported", "Existing remote options are invalid", false)
	}
	return startConfiguration(engineName, backendType, advanced, options)
}

func startConfiguration(engineName, backendType string, advanced bool, initial map[string]string) string {
	configSessionMu.Lock()
	defer configSessionMu.Unlock()
	return startConfigurationLocked(engineName, backendType, advanced, initial)
}

func startConfigurationLocked(engineName, backendType string, advanced bool, initial map[string]string) string {
	if engineName == "" || backendType == "" {
		return failure("unsupported", "Remote name and backend type are required", false)
	}
	runtimeState.RLock()
	sessionActive := runtimeState.session != nil
	runtimeState.RUnlock()
	if sessionActive {
		return failure("conflict", "Another configuration session is active", true)
	}
	info, err := fs.Find(backendType)
	if err != nil {
		return resultError(err)
	}
	values := configmap.Simple{"type": backendType}
	for key, value := range initial {
		if key != "type" {
			values[key] = value
		}
	}
	ctx, cancel := context.WithTimeout(baseContext, 5*time.Minute)
	session := &configurationSession{
		ID: newIdentifier(), EngineName: engineName, Backend: info,
		Values: values, State: fs.ConfigAll, Advanced: advanced, Cancel: cancel,
	}
	runtimeState.Lock()
	runtimeState.session = session
	runtimeState.Unlock()
	out, err := fs.BackendConfig(ctx, engineName, session.Values, info, configmap.Simple{}, fs.ConfigIn{State: session.State})
	if err == nil {
		out, err = applyAdvancedChoice(ctx, session, out)
	}
	if err != nil {
		cancel()
		clearConfigurationSession(session)
		return resultError(err)
	}
	return configurationResult(session, out)
}

func CancelConfiguration(sessionID string) {
	runtimeState.Lock()
	session := runtimeState.session
	if session != nil && session.ID == sessionID {
		runtimeState.session = nil
		session.Cancel()
	}
	runtimeState.Unlock()
}

func ContinueConfiguration(sessionID, answer string) string {
	configSessionMu.Lock()
	defer configSessionMu.Unlock()
	runtimeState.RLock()
	session := runtimeState.session
	runtimeState.RUnlock()
	if session == nil || session.ID != sessionID {
		return failure("notFound", "Configuration session was not found", false)
	}
	if session.Option != nil && session.Option.IsPassword {
		if answer == "" {
			if current, found := session.Values[session.Option.Name]; found {
				answer = current
			}
		} else {
			obscured, obscureErr := obscure.Obscure(answer)
			if obscureErr != nil {
				return resultError(obscureErr)
			}
			answer = obscured
		}
	}
	ctx, cancel := context.WithTimeout(baseContext, 5*time.Minute)
	runtimeState.Lock()
	if runtimeState.session != session {
		runtimeState.Unlock()
		cancel()
		return failure("notFound", "Configuration session was cancelled", false)
	}
	session.Cancel = cancel
	runtimeState.Unlock()
	defer cancel()
	out, err := fs.BackendConfig(ctx, session.EngineName, session.Values, session.Backend, configmap.Simple{}, fs.ConfigIn{State: session.State, Result: answer})
	if err == nil {
		out, err = applyAdvancedChoice(ctx, session, out)
	}
	if err != nil {
		session.Cancel()
		clearConfigurationSession(session)
		return resultError(err)
	}
	return configurationResult(session, out)
}

func applyAdvancedChoice(ctx context.Context, session *configurationSession, out *fs.ConfigOut) (*fs.ConfigOut, error) {
	if out == nil || out.Option == nil || out.Option.Name != "config_fs_advanced" {
		return out, nil
	}
	return fs.BackendConfig(
		ctx,
		session.EngineName,
		session.Values,
		session.Backend,
		configmap.Simple{},
		fs.ConfigIn{State: out.State, Result: fmt.Sprint(session.Advanced)},
	)
}

func configurationResult(session *configurationSession, out *fs.ConfigOut) string {
	if out == nil || out.State == "" {
		values := make(map[string]string, len(session.Values))
		for key, value := range session.Values {
			if key != "type" {
				values[key] = value
			}
		}
		session.Cancel()
		clearConfigurationSession(session)
		return success(map[string]any{"sessionID": session.ID, "status": "complete", "engineName": session.EngineName, "backendType": session.Backend.Name, "options": values})
	}
	session.State = out.State
	session.Option = out.Option
	option := out.Option
	if option != nil {
		option = option.Copy()
		if option.IsPassword {
			option.Default = ""
		} else if current, found := session.Values[option.Name]; found {
			option.Default = current
		}
	}
	if out.Error != "" {
		return success(map[string]any{"sessionID": session.ID, "status": "question", "state": out.State, "message": out.Error, "option": option})
	}
	return success(map[string]any{"sessionID": session.ID, "status": "question", "state": out.State, "option": option})
}

func clearConfigurationSession(session *configurationSession) {
	runtimeState.Lock()
	if runtimeState.session == session {
		runtimeState.session = nil
	}
	runtimeState.Unlock()
}

func ImportConfig(filePath, password string) string {
	configSessionMu.Lock()
	defer configSessionMu.Unlock()
	data, err := os.ReadFile(filePath)
	if err != nil {
		return resultError(err)
	}
	if bytesAreEncrypted(data) && strings.TrimSpace(password) == "" {
		return failure("notAuthenticated", "The rclone configuration password is required", false)
	}
	if password != "" {
		if err := config.SetConfigPassword(password); err != nil {
			return resultError(err)
		}
	}
	defer config.ClearConfigPassword()
	if err := config.SetConfigPath(filePath); err != nil {
		return resultError(err)
	}
	imported := &configfile.Storage{}
	if err := imported.Load(); err != nil {
		restoreMemoryStorage()
		return resultError(err)
	}
	sections := make([]remotePayload, 0)
	requirements := make([]resourceRequirement, 0)
	for _, section := range imported.GetSectionList() {
		backend, found := imported.GetValue(section, "type")
		if !found || backend == "" {
			restoreMemoryStorage()
			return failure("unsupported", fmt.Sprintf("Section %q has no backend type", section), false)
		}
		options := make(map[string]string)
		for _, key := range imported.GetKeyList(section) {
			if key == "type" {
				continue
			}
			value, _ := imported.GetValue(section, key)
			options[key] = value
			if kind, required := resourceOptionKind(backend, key); required && strings.TrimSpace(value) != "" {
				requirements = append(requirements, resourceRequirement{
					EngineName: section, BackendType: backend, OptionName: key,
					Path: value, Kind: kind,
				})
			}
		}
		sections = append(sections, remotePayload{EngineName: section, BackendType: backend, Options: options})
	}
	restoreMemoryStorage()
	return success(map[string]any{
		"sections": sections, "encrypted": bytesAreEncrypted(data),
		"resourceRequirements": requirements,
	})
}

func ExportConfig(configJSON, password, destinationPath string) string {
	storage, err := storageFromVault(configJSON)
	if err != nil {
		return resultError(err)
	}
	serialized, err := storage.Serialize()
	if err != nil {
		return resultError(err)
	}
	file, err := os.OpenFile(destinationPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return resultError(err)
	}
	remove := true
	defer func() {
		_ = file.Close()
		if remove {
			_ = os.Remove(destinationPath)
		}
	}()
	if password == "" {
		_, err = io.WriteString(file, serialized)
	} else {
		if err = config.SetConfigPassword(password); err == nil {
			err = config.Encrypt(strings.NewReader(serialized), file)
		}
		config.ClearConfigPassword()
	}
	if err != nil {
		return resultError(err)
	}
	if err = file.Sync(); err != nil {
		return resultError(err)
	}
	if err = file.Close(); err != nil {
		return resultError(err)
	}
	remove = false
	return success(map[string]any{"path": destinationPath, "encrypted": password != ""})
}

func Validate(remote, root string) string {
	ctx, cancel := context.WithTimeout(baseContext, 60*time.Second)
	defer cancel()
	f, err := openRemote(ctx, remote, root)
	if err == nil {
		_, err = f.List(ctx, "")
	}
	if err != nil {
		return resultError(err)
	}
	return success(map[string]any{"valid": true, "name": f.Name(), "root": f.Root()})
}

func ValidateConfiguration(backendType, optionsJSON, root string) string {
	if _, err := fs.Find(backendType); err != nil {
		return resultError(err)
	}
	options := configmap.Simple{}
	if err := json.Unmarshal([]byte(optionsJSON), &options); err != nil {
		return resultError(err)
	}
	keys := make([]string, 0, len(options))
	for key := range options {
		if key == "" || strings.ContainsAny(key, ",:='\"") {
			return failure("unsupported", "Invalid backend option name", false)
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var builder strings.Builder
	builder.WriteByte(':')
	builder.WriteString(backendType)
	for _, key := range keys {
		builder.WriteByte(',')
		builder.WriteString(key)
		builder.WriteString("='")
		builder.WriteString(strings.ReplaceAll(options[key], "'", "''"))
		builder.WriteByte('\'')
	}
	builder.WriteByte(':')
	if backendType == "local" {
		builder.WriteString(filepath.ToSlash(filepath.Clean(root)))
	} else {
		builder.WriteString(strings.Trim(strings.ReplaceAll(root, "\\", "/"), "/"))
	}
	ctx, cancel := context.WithTimeout(baseContext, 60*time.Second)
	defer cancel()
	f, err := fs.NewFs(ctx, builder.String())
	if err == nil {
		_, err = f.List(ctx, "")
	}
	if err != nil {
		return resultError(err)
	}
	return success(map[string]any{"valid": true, "name": f.Name(), "root": f.Root()})
}

func Capabilities(remote, root string) string {
	ctx, cancel := context.WithTimeout(baseContext, 30*time.Second)
	defer cancel()
	f, err := openRemote(ctx, remote, root)
	if err != nil {
		return resultError(err)
	}
	features := f.Features()
	readOnly := effectiveReadOnly(remote, make(map[string]bool))
	return success(map[string]any{
		"readOnly": readOnly, "caseInsensitive": features.CaseInsensitive,
		"duplicateFiles": features.DuplicateFiles, "readMimeType": features.ReadMimeType,
		"writeMimeType": features.WriteMimeType, "emptyDirectories": features.CanHaveEmptyDirectories,
		"serverSideCopy": features.Copy != nil, "serverSideMove": features.Move != nil,
		"serverSideDirectoryMove": features.DirMove != nil, "changeNotify": features.ChangeNotify != nil,
		"listP": features.ListP != nil, "listR": features.ListR != nil, "about": features.About != nil,
		"precisionNanoseconds": int64(f.Precision()), "hashes": f.Hashes().Array(),
	})
}

type pageCursor struct {
	SchemaVersion int    `json:"schemaVersion"`
	SessionID     string `json:"sessionID"`
	Generation    string `json:"generation"`
	Offset        int    `json:"offset"`
}

func List(remote, directory, pageToken string, pageSize int) string {
	if pageSize <= 0 || pageSize > 500 {
		pageSize = 500
	}
	cleanDirectory := cleanRemotePathFor(remote, directory)
	offset := 0
	var session listSession
	sessionID := ""
	if pageToken != "" {
		cursor, err := decodeCursor(pageToken)
		if err != nil || cursor.SchemaVersion != schemaVersion {
			return failure("unsupported", "Invalid page token", false)
		}
		runtimeState.Lock()
		var found bool
		session, found = runtimeState.listSessions[cursor.SessionID]
		valid := found && time.Now().Before(session.ExpiresAt)
		if valid {
			session.ExpiresAt = time.Now().Add(5 * time.Minute)
			runtimeState.listSessions[cursor.SessionID] = session
		} else if found {
			delete(runtimeState.listSessions, cursor.SessionID)
		}
		runtimeState.Unlock()
		if !valid || session.Remote != remote || session.Directory != cleanDirectory ||
			session.Generation != cursor.Generation {
			return failure("conflict", "Directory page expired", true)
		}
		ctx, cancel := context.WithTimeout(baseContext, 2*time.Minute)
		f, liveErr := openRemote(ctx, remote, "")
		if liveErr == nil {
			var liveEntries fs.DirEntries
			liveEntries, liveErr = f.List(ctx, cleanDirectory)
			if liveErr == nil {
				if len(liveEntries) != len(session.Items) ||
					firstPageGeneration(ctx, liveEntries, min(pageSize, len(liveEntries))) !=
						firstSessionPageGeneration(session.Items, min(pageSize, len(session.Items))) {
					liveErr = errors.New("conflict: directory page expired")
				}
			}
		}
		cancel()
		if liveErr != nil {
			runtimeState.Lock()
			delete(runtimeState.listSessions, cursor.SessionID)
			runtimeState.Unlock()
			return failure("conflict", "Directory page expired", true)
		}
		sessionID = cursor.SessionID
		offset = cursor.Offset
	} else {
		ctx, cancel := context.WithTimeout(baseContext, 2*time.Minute)
		defer cancel()
		f, err := openRemote(ctx, remote, "")
		if err != nil {
			return resultError(err)
		}
		entries, err := f.List(ctx, cleanDirectory)
		if err != nil {
			return resultError(err)
		}
		sort.Slice(entries, func(i, j int) bool { return fs.CompareDirEntries(entries[i], entries[j]) < 0 })
		session = listSession{
			Remote: remote, Directory: cleanDirectory, Generation: entryGeneration(ctx, entries),
			Items: make([]map[string]any, 0, len(entries)), ExpiresAt: time.Now().Add(5 * time.Minute),
		}
		for _, entry := range entries {
			session.Items = append(session.Items, describeEntry(ctx, entry))
		}
		rememberListedDirectory(remote, cleanDirectory)
		sessionID = newIdentifier()
		runtimeState.Lock()
		now := time.Now()
		for id, current := range runtimeState.listSessions {
			if now.After(current.ExpiresAt) {
				delete(runtimeState.listSessions, id)
			}
		}
		if len(runtimeState.listSessions) >= 8 {
			oldestID := ""
			var oldestExpiry time.Time
			for id, current := range runtimeState.listSessions {
				if oldestID == "" || current.ExpiresAt.Before(oldestExpiry) {
					oldestID, oldestExpiry = id, current.ExpiresAt
				}
			}
			delete(runtimeState.listSessions, oldestID)
		}
		runtimeState.listSessions[sessionID] = session
		runtimeState.Unlock()
	}
	if offset < 0 || offset > len(session.Items) {
		return failure("conflict", "Directory page expired", true)
	}
	end := min(offset+pageSize, len(session.Items))
	next := ""
	if end < len(session.Items) {
		next = encodeCursor(pageCursor{
			SchemaVersion: schemaVersion, SessionID: sessionID,
			Generation: session.Generation, Offset: end,
		})
	} else {
		runtimeState.Lock()
		delete(runtimeState.listSessions, sessionID)
		runtimeState.Unlock()
	}
	return success(map[string]any{
		"items": session.Items[offset:end], "nextPageToken": next, "generation": session.Generation,
	})
}

func Stat(remote, path, objectID string) string {
	ctx, cancel := context.WithTimeout(baseContext, 30*time.Second)
	defer cancel()
	f, err := openRemote(ctx, remote, "")
	if err != nil {
		return resultError(err)
	}
	entry, err := resolveEntry(ctx, f, remote, path, objectID)
	if err != nil {
		return resultError(err)
	}
	return success(describeEntry(ctx, entry))
}

func Download(operationID, remote, path, objectID, destinationPath string, offset, length int64) string {
	if offset < 0 || length < 0 {
		return failure("unsupported", "Download range must not be negative", false)
	}
	ctx, done, err := operationContext(operationID)
	if err != nil {
		return resultError(err)
	}
	defer done()
	f, err := openRemote(ctx, remote, "")
	if err != nil {
		return resultError(err)
	}
	entry, err := resolveEntry(ctx, f, remote, path, objectID)
	if err != nil {
		return resultError(err)
	}
	object, ok := entry.(fs.Object)
	if !ok {
		return failure("unsupported", "The requested item is a directory", false)
	}
	var options []fs.OpenOption
	if offset > 0 || length > 0 {
		end := int64(-1)
		if length > 0 {
			end = offset + length - 1
		}
		options = append(options, &fs.RangeOption{Start: offset, End: end})
	}
	reader, err := object.Open(ctx, options...)
	if err != nil {
		return resultError(err)
	}
	defer reader.Close()
	file, err := os.OpenFile(destinationPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return resultError(err)
	}
	remove := true
	defer func() {
		_ = file.Close()
		if remove {
			_ = os.Remove(destinationPath)
		}
	}()
	total := int64(-1)
	if object.Size() >= 0 {
		total = max(object.Size()-offset, 0)
	}
	if length > 0 && (total < 0 || length < total) {
		total = length
	}
	written, err := writeDownloadStage(file, reader, operationID, offset, total)
	if err != nil {
		return resultError(err)
	}
	remove = false
	return success(map[string]any{"bytes": written, "fingerprint": fingerprintObject(ctx, object)})
}

func writeDownloadStage(file *os.File, reader io.Reader, operationID string, offset, total int64) (int64, error) {
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return 0, err
	}
	written, err := copySparseDownload(
		file,
		&progressReader{reader: reader, operationID: operationID, total: total},
	)
	if err == nil && total >= 0 && written != total {
		err = fmt.Errorf("short transfer: received %d of %d bytes", written, total)
	}
	if err == nil {
		err = file.Truncate(offset + written)
	}
	if err == nil {
		var info os.FileInfo
		info, err = file.Stat()
		if err == nil && info.Size() != offset+written {
			err = fmt.Errorf("staged range length %d does not match expected %d", info.Size(), offset+written)
		}
	}
	if err == nil {
		err = file.Sync()
	}
	return written, err
}

func copySparseDownload(destination *os.File, source io.Reader) (int64, error) {
	const bufferSize = 256 * 1024
	buffer := make([]byte, bufferSize)
	var written int64
	for {
		count, readErr := source.Read(buffer)
		if count > 0 {
			chunk := buffer[:count]
			var writeErr error
			if isZeroFilled(chunk) {
				_, writeErr = destination.Seek(int64(count), io.SeekCurrent)
			} else {
				_, writeErr = destination.Write(chunk)
			}
			written += int64(count)
			if writeErr != nil {
				return written, writeErr
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return written, nil
			}
			return written, readErr
		}
		if count == 0 {
			return written, io.ErrNoProgress
		}
	}
}

func isZeroFilled(data []byte) bool {
	for _, value := range data {
		if value != 0 {
			return false
		}
	}
	return true
}

func Upload(operationID, remote, path, sourcePath, expectedVersion string) string {
	ctx, done, err := operationContext(operationID)
	if err != nil {
		return resultError(err)
	}
	defer done()
	f, err := openRemote(ctx, remote, "")
	if err != nil {
		return resultError(err)
	}
	// Validation is repeated after staging so a concurrent remote mutation cannot
	// be overwritten between the first check and promotion.
	file, err := os.Open(sourcePath)
	if err != nil {
		return resultError(err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return resultError(err)
	}
	cleanDestination := cleanRemotePathFor(remote, path)
	parent, _ := splitRemotePath(cleanDestination)
	operationDigest := sha256.Sum256([]byte(operationID))
	temporaryPath := joinRemotePath(
		parent,
		".mountli-upload-"+hex.EncodeToString(operationDigest[:12]),
	)
	if ownedStage, lookupErr := f.NewObject(ctx, temporaryPath); lookupErr == nil {
		if err = operations.DeleteFile(ctx, ownedStage); err != nil {
			return resultError(err)
		}
	} else if !errors.Is(lookupErr, fs.ErrorObjectNotFound) && !errors.Is(lookupErr, fs.ErrorDirNotFound) {
		return resultError(lookupErr)
	}
	if err = injectMutationFault("upload.before-stage"); err != nil {
		return resultError(err)
	}
	hashType := f.Hashes().Overlap(hash.Supported()).GetOne()
	var sourceHasher *hash.MultiHasher
	var sourceReader io.Reader = file
	if hashType != hash.None {
		sourceHasher, err = hash.NewMultiHasherTypes(hash.NewHashSet(hashType))
		if err != nil {
			return resultError(err)
		}
		sourceReader = io.TeeReader(file, sourceHasher)
	}
	reader := &progressReadCloser{
		ReadCloser: struct {
			io.Reader
			io.Closer
		}{Reader: sourceReader, Closer: file},
		operationID: operationID,
		total:       info.Size(),
	}
	temporary, err := operations.RcatSize(ctx, f, temporaryPath, reader, info.Size(), info.ModTime(), nil)
	if err != nil {
		return resultError(err)
	}
	removeTemporary := true
	defer func() {
		if removeTemporary && injectMutationFault("upload.before-cleanup") == nil {
			_ = operations.DeleteFile(context.Background(), temporary)
		}
	}()
	if err = injectMutationFault("upload.after-stage"); err != nil {
		return resultError(err)
	}
	if temporary.Size() != info.Size() {
		return resultError(fmt.Errorf("short transfer: staged %d of %d bytes", temporary.Size(), info.Size()))
	}
	if sourceHasher != nil {
		sourceHash, hashErr := sourceHasher.SumString(hashType, false)
		if hashErr != nil {
			return resultError(hashErr)
		}
		stagedHash, hashErr := temporary.Hash(ctx, hashType)
		if hashErr != nil {
			return resultError(hashErr)
		}
		if stagedHash != "" && stagedHash != sourceHash {
			return resultError(fmt.Errorf("staged upload hash mismatch"))
		}
	}
	if err = verifyDestinationVersion(ctx, f, remote, path, expectedVersion); err != nil {
		existing, lookupErr := f.NewObject(ctx, cleanDestination)
		if lookupErr == nil {
			equal, compareErr := equalObjectContents(ctx, temporary, existing, hashType)
			if compareErr == nil && equal {
				return success(describeEntry(ctx, existing))
			}
		}
		return resultError(err)
	}
	if err = injectMutationFault("upload.before-promote"); err != nil {
		return resultError(err)
	}
	var object fs.Object
	if move := f.Features().Move; move != nil {
		object, err = move(ctx, temporary, cleanDestination)
		if err == nil {
			removeTemporary = false
		}
	} else {
		stagedReader, openErr := temporary.Open(ctx)
		if openErr != nil {
			return resultError(openErr)
		}
		object, err = operations.RcatSize(ctx, f, cleanDestination, stagedReader, info.Size(), info.ModTime(), nil)
		_ = stagedReader.Close()
	}
	if err != nil {
		return resultError(err)
	}
	if err = injectMutationFault("upload.after-promote"); err != nil {
		return resultError(err)
	}
	if object.Size() != info.Size() {
		return resultError(fmt.Errorf("short transfer: promoted %d of %d bytes", object.Size(), info.Size()))
	}
	if sourceHasher != nil {
		sourceHash, hashErr := sourceHasher.SumString(hashType, false)
		if hashErr != nil {
			return resultError(hashErr)
		}
		promotedHash, hashErr := object.Hash(ctx, hashType)
		if hashErr != nil {
			return resultError(hashErr)
		}
		if promotedHash != "" && promotedHash != sourceHash {
			return resultError(fmt.Errorf("promoted upload hash mismatch"))
		}
	}
	invalidateListSessions()
	return success(describeEntry(ctx, object))
}

func equalObjectContents(ctx context.Context, first, second fs.Object, hashType hash.Type) (bool, error) {
	if first.Size() != second.Size() {
		return false, nil
	}
	if hashType != hash.None {
		firstHash, err := first.Hash(ctx, hashType)
		if err != nil {
			return false, err
		}
		secondHash, err := second.Hash(ctx, hashType)
		if err != nil {
			return false, err
		}
		if firstHash != "" && secondHash != "" {
			return firstHash == secondHash, nil
		}
	}
	firstReader, err := first.Open(ctx)
	if err != nil {
		return false, err
	}
	defer firstReader.Close()
	secondReader, err := second.Open(ctx)
	if err != nil {
		return false, err
	}
	defer secondReader.Close()
	const bufferSize = 256 * 1024
	firstBuffer := make([]byte, bufferSize)
	secondBuffer := make([]byte, bufferSize)
	for {
		firstCount, firstErr := io.ReadFull(firstReader, firstBuffer)
		secondCount, secondErr := io.ReadFull(secondReader, secondBuffer)
		if firstCount != secondCount || !bytes.Equal(firstBuffer[:firstCount], secondBuffer[:secondCount]) {
			return false, nil
		}
		if errors.Is(firstErr, io.EOF) || errors.Is(firstErr, io.ErrUnexpectedEOF) {
			return errors.Is(secondErr, io.EOF) || errors.Is(secondErr, io.ErrUnexpectedEOF), nil
		}
		if firstErr != nil {
			return false, firstErr
		}
		if secondErr != nil {
			return false, secondErr
		}
	}
}

func MakeDirectory(operationID, remote, path string) string {
	ctx, done, err := operationContext(operationID)
	if err != nil {
		return resultError(err)
	}
	defer done()
	f, err := openRemote(ctx, remote, "")
	if err == nil {
		err = verifyDestinationVersion(ctx, f, remote, path, "")
	}
	if err == nil {
		err = operations.Mkdir(ctx, f, cleanRemotePathFor(remote, path))
	}
	if err != nil {
		return resultError(err)
	}
	invalidateListSessions()
	return success(map[string]any{"path": cleanRemotePathFor(remote, path)})
}

func Move(operationID, remote, sourcePath, sourceObjectID, destinationPath, expectedSourceVersion, expectedDestinationVersion string) string {
	ctx, done, err := operationContext(operationID)
	if err != nil {
		return resultError(err)
	}
	defer done()
	f, err := openRemote(ctx, remote, "")
	if err != nil {
		return resultError(err)
	}
	source, err := resolveEntry(ctx, f, remote, sourcePath, sourceObjectID)
	if err != nil {
		return resultError(err)
	}
	if object, ok := source.(fs.Object); ok {
		if expectedSourceVersion != "" && fingerprintObject(ctx, object) != expectedSourceVersion {
			return resultError(errors.New("conflict: remote version changed"))
		}
		if err = verifyDestinationVersion(ctx, f, remote, destinationPath, expectedDestinationVersion); err == nil {
			_, err = operations.Move(ctx, f, nil, cleanRemotePathFor(remote, destinationPath), object)
		}
	} else {
		if err = verifyDestinationVersion(ctx, f, remote, destinationPath, expectedDestinationVersion); err == nil {
			err = operations.DirMove(ctx, f, source.Remote(), cleanRemotePathFor(remote, destinationPath))
		}
	}
	if err != nil {
		return resultError(err)
	}
	invalidateListSessions()
	return Stat(remote, destinationPath, "")
}

func Delete(operationID, remote, path, objectID, expectedVersion string) string {
	ctx, done, err := operationContext(operationID)
	if err != nil {
		return resultError(err)
	}
	defer done()
	f, err := openRemote(ctx, remote, "")
	if err != nil {
		return resultError(err)
	}
	entry, err := resolveEntry(ctx, f, remote, path, objectID)
	if err != nil {
		if errors.Is(err, fs.ErrorObjectNotFound) || errors.Is(err, fs.ErrorDirNotFound) {
			return success(map[string]any{"deleted": true})
		}
		return resultError(err)
	}
	if err = injectMutationFault("delete.before-remote"); err != nil {
		return resultError(err)
	}
	if object, ok := entry.(fs.Object); ok {
		if expectedVersion != "" && fingerprintObject(ctx, object) != expectedVersion {
			return resultError(errors.New("conflict: remote version changed"))
		}
		err = operations.DeleteFile(ctx, object)
	} else {
		err = operations.Purge(ctx, f, entry.Remote())
	}
	if err != nil {
		return resultError(err)
	}
	if err = injectMutationFault("delete.after-remote"); err != nil {
		return resultError(err)
	}
	invalidateListSessions()
	return success(map[string]any{"deleted": true})
}

func About(remote, root string) string {
	ctx, cancel := context.WithTimeout(baseContext, 30*time.Second)
	defer cancel()
	f, err := openRemote(ctx, remote, root)
	if err != nil {
		return resultError(err)
	}
	if f.Features().About == nil {
		return failure("unsupported", "This backend does not report quota", false)
	}
	usage, err := f.Features().About(ctx)
	if err != nil {
		return resultError(err)
	}
	return success(usage)
}

func PollChanges(remote, root string) string {
	ctx, cancel := context.WithTimeout(baseContext, 2*time.Minute)
	defer cancel()
	f, err := openRemote(ctx, remote, root)
	if err != nil {
		return resultError(err)
	}
	entries, err := f.List(ctx, "")
	if err != nil {
		return resultError(err)
	}
	paths := make([]string, 0, len(entries))
	for _, entry := range entries {
		paths = append(paths, pathWithinRoot(remote, root, entry.Remote()))
	}
	sort.Strings(paths)
	return success(map[string]any{"paths": paths, "generation": entryGeneration(ctx, entries)})
}

func StartChangeNotifications(watcherID, remote, root string, intervalSeconds int) string {
	if watcherID == "" {
		return failure("unsupported", "Watcher identifier is required", false)
	}
	ctx, cancel := context.WithCancel(baseContext)
	f, err := openRemote(ctx, remote, root)
	if err != nil {
		cancel()
		return resultError(err)
	}
	runtimeState.Lock()
	if _, exists := runtimeState.watchers[watcherID]; exists {
		runtimeState.Unlock()
		cancel()
		return failure("alreadyExists", "Watcher already exists", false)
	}
	runtimeState.watchers[watcherID] = watcher{
		cancel: cancel, remote: remote, root: cleanRemotePathFor(remote, root),
		directories: map[string]string{"": ""},
	}
	runtimeState.Unlock()
	if intervalSeconds < 30 {
		intervalSeconds = 30
	}
	if notify := f.Features().ChangeNotify; notify != nil {
		interval := make(chan time.Duration, 1)
		interval <- time.Duration(intervalSeconds) * time.Second
		go func() {
			defer close(interval)
			notify(ctx, func(path string, _ fs.EntryType) {
				publishChanges(watcherID, []string{pathWithinRoot(remote, root, path)})
			}, interval)
		}()
	} else {
		go pollWatcher(ctx, watcherID, remote, root, f, time.Duration(intervalSeconds)*time.Second)
	}
	return success(map[string]any{"watcherID": watcherID, "native": f.Features().ChangeNotify != nil})
}

func StopChangeNotifications(watcherID string) {
	runtimeState.Lock()
	if current, ok := runtimeState.watchers[watcherID]; ok {
		current.cancel()
		delete(runtimeState.watchers, watcherID)
	}
	runtimeState.Unlock()
}

func Cancel(operationID string) {
	runtimeState.RLock()
	cancel := runtimeState.operations[operationID]
	runtimeState.RUnlock()
	if cancel != nil {
		cancel()
	}
}

func pathWithinRoot(remote, root, path string) string {
	cleanRoot := cleanRemotePathFor(remote, root)
	cleanPath := strings.Trim(cleanRemotePathFor(remote, path), "/")
	if cleanRoot == "" {
		return cleanPath
	}
	if cleanPath == "" {
		return cleanRoot
	}
	return strings.Trim(cleanRoot, "/") + "/" + cleanPath
}

func Shutdown() {
	runtimeState.Lock()
	for _, cancel := range runtimeState.operations {
		cancel()
	}
	for _, current := range runtimeState.watchers {
		current.cancel()
	}
	if runtimeState.session != nil {
		runtimeState.session.Cancel()
	}
	runtimeState.operations = make(map[string]context.CancelFunc)
	runtimeState.watchers = make(map[string]watcher)
	runtimeState.listSessions = make(map[string]listSession)
	runtimeState.session = nil
	runtimeState.progress = nil
	runtimeState.vaultMutation = nil
	runtimeState.oauth = nil
	runtimeState.changes = nil
	runtimeState.storage = newMemoryStorage()
	runtimeState.lastMutationErr = nil
	storage := runtimeState.storage
	runtimeState.Unlock()
	cache.Clear()
	_ = config.SetConfigPath(memoryConfigPath)
	config.SetData(storage)
	config.ClearConfigPassword()
}

func openRemote(ctx context.Context, remote, root string) (fs.Fs, error) {
	if remote == "" {
		return nil, errors.New("remote name is required")
	}
	if configuredBackendType(remote) == "local" {
		if root == "" {
			root = "/"
		} else {
			root = filepath.ToSlash(filepath.Clean(root))
		}
		return fs.NewFs(ctx, remote+":"+root)
	}
	return fs.NewFs(ctx, remote+":"+cleanRemotePathFor(remote, root))
}

func cleanRemotePathFor(remote, path string) string {
	normalized := strings.ReplaceAll(path, "\\", "/")
	if configuredBackendType(remote) == "local" {
		if normalized == "" || normalized == "." || normalized == "/" {
			return ""
		}
		return strings.TrimPrefix(filepath.ToSlash(filepath.Clean(normalized)), "/")
	}
	return strings.Trim(normalized, "/")
}

func operationContext(operationID string) (context.Context, func(), error) {
	if operationID == "" {
		return nil, nil, errors.New("operation identifier is required")
	}
	ctx, cancel := context.WithCancel(baseContext)
	runtimeState.Lock()
	if _, exists := runtimeState.operations[operationID]; exists {
		runtimeState.Unlock()
		cancel()
		return nil, nil, fmt.Errorf("operation %q already exists", operationID)
	}
	runtimeState.operations[operationID] = cancel
	runtimeState.Unlock()
	return ctx, func() {
		cancel()
		runtimeState.Lock()
		delete(runtimeState.operations, operationID)
		runtimeState.Unlock()
	}, nil
}

func describeEntry(ctx context.Context, entry fs.DirEntry) map[string]any {
	item := map[string]any{
		"path": entry.Remote(), "name": filepath.Base(entry.Remote()),
		"size": entry.Size(), "modTime": entry.ModTime(ctx).UTC().Format(time.RFC3339Nano),
		"isDirectory": false,
	}
	if _, ok := entry.(fs.Directory); ok {
		item["isDirectory"] = true
	}
	if ider, ok := entry.(fs.IDer); ok {
		item["objectID"] = ider.ID()
	}
	if object, ok := entry.(fs.Object); ok {
		item["fingerprint"] = fingerprintObject(ctx, object)
		item["mimeType"] = fs.MimeType(ctx, object)
	}
	return item
}
func invalidateListSessions() {
	runtimeState.Lock()
	runtimeState.listSessions = make(map[string]listSession)
	runtimeState.Unlock()
}

func fingerprintObject(ctx context.Context, object fs.Object) string {
	return fs.Fingerprint(ctx, object, false)
}

func verifyDestinationVersion(ctx context.Context, f fs.Fs, remote, path, expected string) error {
	entry, err := resolveEntry(ctx, f, remote, path, "")
	if expected == "" {
		if err == nil {
			return errors.New("destination already exists")
		}
		if errors.Is(err, fs.ErrorObjectNotFound) || errors.Is(err, fs.ErrorDirNotFound) {
			return nil
		}
		return err
	}
	if err != nil {
		return err
	}
	object, ok := entry.(fs.Object)
	if !ok || fingerprintObject(ctx, object) != expected {
		return fmt.Errorf("conflict: remote version changed")
	}
	return nil
}

func resolveEntry(ctx context.Context, f fs.Fs, remote, path, objectID string) (fs.DirEntry, error) {
	cleanPath := cleanRemotePathFor(remote, path)
	parent, name := splitRemotePath(cleanPath)
	entries, err := f.List(ctx, parent)
	if err != nil {
		return nil, err
	}
	return findListedEntry(entries, cleanPath, name, objectID)
}

func findListedEntry(entries fs.DirEntries, cleanPath, name, objectID string) (fs.DirEntry, error) {
	for _, entry := range entries {
		if objectID != "" {
			ider, ok := entry.(fs.IDer)
			if ok && ider.ID() == objectID {
				return entry, nil
			}
			continue
		}
		if entry.Remote() == cleanPath || pathBase(entry.Remote()) == name {
			return entry, nil
		}
	}
	return nil, fs.ErrorObjectNotFound
}

func splitRemotePath(path string) (string, string) {
	index := strings.LastIndex(path, "/")
	if index < 0 {
		return "", path
	}
	return path[:index], path[index+1:]
}

func joinRemotePath(parent, name string) string {
	if parent == "" {
		return name
	}
	return parent + "/" + name
}

func pathBase(path string) string {
	_, name := splitRemotePath(strings.Trim(path, "/"))
	return name
}

type resourceRequirement struct {
	EngineName  string `json:"engineName"`
	BackendType string `json:"backendType"`
	OptionName  string `json:"optionName"`
	Path        string `json:"path"`
	Kind        string `json:"kind"`
}

func resourceOptionKind(backend, key string) (string, bool) {
	switch key {
	case "key_file":
		return "sshPrivateKey", true
	case "pubkey_file":
		return "sshPublicKey", true
	case "known_hosts_file":
		return "knownHosts", true
	case "client_certificate_path", "client_cert":
		return "clientCertificate", true
	case "client_key":
		return "clientPrivateKey", true
	case "ca_cert":
		return "certificateAuthority", true
	case "service_account_file", "service_principal_file", "box_config_file",
		"config_file", "shared_credentials_file", "sse_customer_key_file":
		return "configurationFile", true
	case "kerberos_ccache":
		return "credentialCache", true
	case "db_path", "chunk_path", "tmp_upload_path":
		if backend == "cache" {
			return "managedDirectory", true
		}
	}
	return "", false
}

func entryGeneration(_ context.Context, entries fs.DirEntries) string {
	sort.Slice(entries, func(i, j int) bool {
		return fs.CompareDirEntries(entries[i], entries[j]) < 0
	})
	hasher := sha256.New()
	for _, entry := range entries {
		_, _ = io.WriteString(hasher, entry.Remote())
		_, _ = io.WriteString(hasher, "\x00")
		_, _ = io.WriteString(hasher, strconv.FormatInt(entry.Size(), 10))
		_, _ = io.WriteString(hasher, "\x00")
	}
	return hex.EncodeToString(hasher.Sum(nil))
}

func encodeCursor(cursor pageCursor) string {
	data, _ := json.Marshal(cursor)
	return base64.RawURLEncoding.EncodeToString(data)
}

func decodeCursor(token string) (pageCursor, error) {
	var cursor pageCursor
	data, err := base64.RawURLEncoding.DecodeString(token)
	if err == nil {
		err = json.Unmarshal(data, &cursor)
	}
	return cursor, err
}

func newIdentifier() string {
	data := make([]byte, 16)
	if _, err := rand.Read(data); err != nil {
		sum := sha256.Sum256([]byte(fmt.Sprintf("%d", time.Now().UnixNano())))
		data = sum[:16]
	}
	return hex.EncodeToString(data)
}

func firstPageGeneration(ctx context.Context, entries fs.DirEntries, count int) string {
	sort.Slice(entries, func(i, j int) bool {
		return fs.CompareDirEntries(entries[i], entries[j]) < 0
	})
	hasher := sha256.New()
	for _, entry := range entries[:count] {
		_, _ = io.WriteString(hasher, entry.Remote())
		_, _ = io.WriteString(hasher, "\x00")
		_, _ = io.WriteString(hasher, strconv.FormatInt(entry.Size(), 10))
		_, _ = io.WriteString(hasher, "\x00")
	}
	return hex.EncodeToString(hasher.Sum(nil))
}

func firstSessionPageGeneration(items []map[string]any, count int) string {
	hasher := sha256.New()
	for _, item := range items[:count] {
		_, _ = io.WriteString(hasher, fmt.Sprint(item["path"]))
		_, _ = io.WriteString(hasher, "\x00")
		_, _ = io.WriteString(hasher, strconv.FormatInt(item["size"].(int64), 10))
		_, _ = io.WriteString(hasher, "\x00")
	}
	return hex.EncodeToString(hasher.Sum(nil))
}

func success(data any) string {
	encoded, _ := json.Marshal(envelope{SchemaVersion: schemaVersion, Data: data})
	return string(encoded)
}

func failure(kind, message string, retryable bool) string {
	encoded, _ := json.Marshal(envelope{SchemaVersion: schemaVersion, Error: &bridgeError{Kind: kind, Message: message, Retryable: retryable}})
	return string(encoded)
}

func resultError(err error) string {
	mapped := mapError(err)
	encoded, _ := json.Marshal(envelope{SchemaVersion: schemaVersion, Error: mapped})
	return string(encoded)
}

func mapError(err error) *bridgeError {
	if err == nil {
		return nil
	}
	message := err.Error()
	lower := strings.ToLower(message)
	switch {
	case errors.Is(err, context.Canceled):
		return &bridgeError{Kind: "cancelled", Message: message, Retryable: false}
	case errors.Is(err, context.DeadlineExceeded):
		return &bridgeError{Kind: "unreachable", Message: message, Retryable: true}
	case errors.Is(err, fs.ErrorObjectNotFound), errors.Is(err, fs.ErrorDirNotFound), os.IsNotExist(err):
		return &bridgeError{Kind: "notFound", Message: message, Retryable: false}
	case errors.Is(err, fs.ErrorDirExists), errors.Is(err, fs.ErrorIsFile), strings.Contains(lower, "already exists"):
		return &bridgeError{Kind: "alreadyExists", Message: message, Retryable: false}
	case strings.Contains(lower, "authentication"), strings.Contains(lower, "unauthorized"), strings.Contains(lower, "invalid_grant"), strings.Contains(lower, "password"):
		return &bridgeError{Kind: "notAuthenticated", Message: message, Retryable: false}
	case strings.Contains(lower, "quota"), strings.Contains(lower, "insufficient storage"):
		return &bridgeError{Kind: "quotaExceeded", Message: message, Retryable: false}
	case strings.Contains(lower, "permission"), strings.Contains(lower, "access denied"):
		return &bridgeError{Kind: "permissionDenied", Message: message, Retryable: false}
	case strings.Contains(lower, "conflict"), strings.Contains(lower, "version changed"):
		return &bridgeError{Kind: "conflict", Message: message, Retryable: false}
	case strings.Contains(lower, "unsupported"), errors.Is(err, fs.ErrorCantMove), errors.Is(err, fs.ErrorCantCopy):
		return &bridgeError{Kind: "unsupported", Message: message, Retryable: false}
	case strings.Contains(lower, "short transfer"), strings.Contains(lower, "hash mismatch"):
		return &bridgeError{Kind: "unreachable", Message: message, Retryable: true}
	case strings.Contains(lower, "timeout"), strings.Contains(lower, "connection"), strings.Contains(lower, "network"), strings.Contains(lower, "tls"):
		return &bridgeError{Kind: "unreachable", Message: message, Retryable: true}
	default:
		return &bridgeError{Kind: "internal", Message: message, Retryable: false}
	}
}

func bytesAreEncrypted(data []byte) bool {
	return strings.HasPrefix(string(data), "RCLONE_ENCRYPT_V0:")
}

func restoreMemoryStorage() {
	_ = config.SetConfigPath(memoryConfigPath)
	runtimeState.RLock()
	storage := runtimeState.storage
	runtimeState.RUnlock()
	config.SetData(storage)
}

func configuredBackendType(remote string) string {
	runtimeState.RLock()
	storage := runtimeState.storage
	runtimeState.RUnlock()
	backend, _ := storage.GetValue(remote, "type")
	return backend
}
func effectiveReadOnly(remote string, visiting map[string]bool) bool {
	if visiting[remote] {
		return false
	}
	visiting[remote] = true
	defer delete(visiting, remote)
	runtimeState.RLock()
	storage := runtimeState.storage
	runtimeState.RUnlock()
	backend, _ := storage.GetValue(remote, "type")
	if backend == "http" || backend == "archive" {
		return true
	}
	var dependencyValues []string
	switch backend {
	case "alias", "cache", "chunker", "compress", "crypt", "hasher":
		if value, found := storage.GetValue(remote, "remote"); found {
			dependencyValues = append(dependencyValues, value)
		}
	case "combine", "union":
		if value, found := storage.GetValue(remote, "upstreams"); found {
			dependencyValues = append(dependencyValues, value)
			if backend == "union" && containsReadOnlyUpstream(value) {
				return true
			}
		}
	}
	for _, value := range dependencyValues {
		for _, candidate := range storage.GetSectionList() {
			if containsRemoteReference(value, candidate) && effectiveReadOnly(candidate, visiting) {
				return true
			}
		}
	}
	return false
}

func containsRemoteReference(value, remote string) bool {
	needle := remote + ":"
	for offset := 0; ; {
		index := strings.Index(value[offset:], needle)
		if index < 0 {
			return false
		}
		index += offset
		if index == 0 || strings.ContainsRune(" \t\r\n\"'=,", rune(value[index-1])) {
			return true
		}
		offset = index + len(needle)
	}
}

func containsReadOnlyUpstream(value string) bool {
	for offset := 0; ; {
		index := strings.Index(value[offset:], ":ro")
		if index < 0 {
			return false
		}
		index += offset
		end := index + len(":ro")
		if end == len(value) || strings.ContainsRune(" \t\r\n\"'", rune(value[end])) {
			return true
		}
		offset = end
	}
}

func publishProgress(operationID string, completed, total int64) {
	runtimeState.RLock()
	listener := runtimeState.progress
	runtimeState.RUnlock()
	if listener != nil {
		listener.OnProgress(operationID, completed, total)
	}
}

type progressReader struct {
	reader        io.Reader
	operationID   string
	total         int64
	completed     int64
	lastPublished time.Time
}

func (r *progressReader) Read(buffer []byte) (int, error) {
	n, err := r.reader.Read(buffer)
	r.completed += int64(n)
	if r.completed == r.total || err != nil || time.Since(r.lastPublished) >= 200*time.Millisecond {
		publishProgress(r.operationID, r.completed, r.total)
		r.lastPublished = time.Now()
	}
	return n, err
}

type progressReadCloser struct {
	io.ReadCloser
	operationID   string
	total         int64
	completed     int64
	lastPublished time.Time
}

func (r *progressReadCloser) Read(buffer []byte) (int, error) {
	n, err := r.ReadCloser.Read(buffer)
	r.completed += int64(n)
	if r.completed == r.total || err != nil || time.Since(r.lastPublished) >= 200*time.Millisecond {
		publishProgress(r.operationID, r.completed, r.total)
		r.lastPublished = time.Now()
	}
	return n, err
}

func pollWatcher(ctx context.Context, watcherID, remote, root string, f fs.Fs, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		runtimeState.RLock()
		current, exists := runtimeState.watchers[watcherID]
		directories := make(map[string]string)
		if exists {
			for directory, generation := range current.directories {
				directories[directory] = generation
			}
		}
		runtimeState.RUnlock()
		if !exists {
			return
		}
		for directory, previous := range directories {
			entries, err := f.List(ctx, directory)
			if err != nil {
				continue
			}
			generation := entryGeneration(ctx, entries)
			if previous != "" && generation != previous {
				publishChanges(watcherID, []string{pathWithinRoot(remote, root, directory)})
			}
			runtimeState.Lock()
			if active, ok := runtimeState.watchers[watcherID]; ok {
				active.directories[directory] = generation
				runtimeState.watchers[watcherID] = active
			}
			runtimeState.Unlock()
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func rememberListedDirectory(remote, directory string) {
	runtimeState.Lock()
	defer runtimeState.Unlock()
	for id, current := range runtimeState.watchers {
		if current.remote != remote {
			continue
		}
		relative, ok := relativeToRoot(current.root, directory)
		if !ok {
			continue
		}
		if _, exists := current.directories[relative]; !exists {
			current.directories[relative] = ""
			runtimeState.watchers[id] = current
		}
	}
}

func relativeToRoot(root, path string) (string, bool) {
	cleanRoot := strings.Trim(root, "/")
	cleanPath := strings.Trim(path, "/")
	if cleanRoot == "" {
		return cleanPath, true
	}
	if cleanPath == cleanRoot {
		return "", true
	}
	prefix := cleanRoot + "/"
	if !strings.HasPrefix(cleanPath, prefix) {
		return "", false
	}
	return strings.TrimPrefix(cleanPath, prefix), true
}

func publishChanges(watcherID string, paths []string) {
	data, _ := json.Marshal(paths)
	runtimeState.RLock()
	listener := runtimeState.changes
	runtimeState.RUnlock()
	if listener != nil {
		go listener.OnChange(watcherID, string(data))
	}
}

func publishMutation(value mutation) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	runtimeState.RLock()
	listener := runtimeState.vaultMutation
	runtimeState.RUnlock()
	if listener == nil {
		return nil
	}
	response := listener.OnMutation(string(data))
	if response == "" {
		return nil
	}
	var result envelope
	if err := json.Unmarshal([]byte(response), &result); err != nil {
		return fmt.Errorf("invalid vault mutation response: %w", err)
	}
	if result.Error != nil {
		return errors.New(result.Error.Message)
	}
	return nil
}

func setMutationError(err error) {
	runtimeState.Lock()
	runtimeState.lastMutationErr = err
	runtimeState.Unlock()
}

func mutationError() error {
	runtimeState.RLock()
	defer runtimeState.RUnlock()
	return runtimeState.lastMutationErr
}
