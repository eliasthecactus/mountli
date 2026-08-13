package mountli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"

	"github.com/rclone/rclone/fs/config"
)

type vaultPayload struct {
	SchemaVersion int             `json:"schemaVersion"`
	Revision      uint64          `json:"revision"`
	Remotes       []remotePayload `json:"remotes"`
}

type remotePayload struct {
	EngineName  string            `json:"engineName"`
	BackendType string            `json:"backendType"`
	Options     map[string]string `json:"options"`
}

type mutation struct {
	SchemaVersion        int    `json:"schemaVersion"`
	ExpectedRevision     uint64 `json:"expectedRevision"`
	Action               string `json:"action"`
	Section              string `json:"section"`
	Key                  string `json:"key,omitempty"`
	Value                string `json:"value,omitempty"`
	PreviousValue        string `json:"previousValue,omitempty"`
	PreviousValuePresent bool   `json:"previousValuePresent"`
}

type memoryStorage struct {
	mutationMu sync.Mutex
	mu         sync.RWMutex
	sections   map[string]map[string]string
	revision   uint64
}

func newMemoryStorage() *memoryStorage {
	return &memoryStorage{sections: make(map[string]map[string]string)}
}

func storageFromVault(raw string) (*memoryStorage, error) {
	var payload vaultPayload
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&payload); err != nil {
		return nil, fmt.Errorf("decode vault: %w", err)
	}
	if payload.SchemaVersion != schemaVersion {
		return nil, fmt.Errorf("unsupported vault schema %d", payload.SchemaVersion)
	}
	storage := newMemoryStorage()
	storage.revision = payload.Revision
	for _, remote := range payload.Remotes {
		if remote.EngineName == "" || remote.BackendType == "" {
			return nil, fmt.Errorf("remote name and backend type are required")
		}
		if _, exists := storage.sections[remote.EngineName]; exists {
			return nil, fmt.Errorf("duplicate remote %q", remote.EngineName)
		}
		section := make(map[string]string, len(remote.Options)+1)
		section["type"] = remote.BackendType
		for key, value := range remote.Options {
			if key == "type" {
				continue
			}
			section[key] = value
		}
		storage.sections[remote.EngineName] = section
	}
	return storage, nil
}

func (s *memoryStorage) GetSectionList() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sections := make([]string, 0, len(s.sections))
	for section := range s.sections {
		sections = append(sections, section)
	}
	sort.Strings(sections)
	return sections
}

func (s *memoryStorage) HasSection(section string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	_, ok := s.sections[section]
	return ok
}

func (s *memoryStorage) DeleteSection(section string) {
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	s.mu.RLock()
	revision := s.revision
	s.mu.RUnlock()
	if err := publishMutation(mutation{SchemaVersion: schemaVersion, ExpectedRevision: revision, Action: "deleteSection", Section: section}); err != nil {
		setMutationError(err)
		return
	}
	s.mu.Lock()
	delete(s.sections, section)
	s.revision++
	s.mu.Unlock()
}

func (s *memoryStorage) GetKeyList(section string) []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	values := s.sections[section]
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func (s *memoryStorage) GetValue(section, key string) (string, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	value, ok := s.sections[section][key]
	return value, ok
}

func (s *memoryStorage) SetValue(section, key, value string) {
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	s.mu.RLock()
	previous, previousPresent := s.sections[section][key]
	revision := s.revision
	s.mu.RUnlock()
	if err := publishMutation(mutation{
		SchemaVersion: schemaVersion, ExpectedRevision: revision, Action: "set",
		Section: section, Key: key, Value: value,
		PreviousValue: previous, PreviousValuePresent: previousPresent,
	}); err != nil {
		setMutationError(err)
		return
	}
	s.mu.Lock()
	values := s.sections[section]
	if values == nil {
		values = make(map[string]string)
		s.sections[section] = values
	}
	values[key] = value
	s.revision++
	s.mu.Unlock()
}

func (s *memoryStorage) DeleteKey(section, key string) bool {
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	s.mu.RLock()
	previous, exists := s.sections[section][key]
	revision := s.revision
	s.mu.RUnlock()
	if !exists {
		return false
	}
	if err := publishMutation(mutation{
		SchemaVersion: schemaVersion, ExpectedRevision: revision, Action: "deleteKey",
		Section: section, Key: key, PreviousValue: previous, PreviousValuePresent: true,
	}); err != nil {
		setMutationError(err)
		return false
	}
	s.mu.Lock()
	delete(s.sections[section], key)
	s.revision++
	s.mu.Unlock()
	return true
}

func (s *memoryStorage) Load() error { return nil }
func (s *memoryStorage) Save() error { return mutationError() }

func (s *memoryStorage) Serialize() (string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var buffer bytes.Buffer
	sections := make([]string, 0, len(s.sections))
	for section := range s.sections {
		sections = append(sections, section)
	}
	sort.Strings(sections)
	for _, section := range sections {
		fmt.Fprintf(&buffer, "[%s]\n", section)
		keys := make([]string, 0, len(s.sections[section]))
		for key := range s.sections[section] {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			fmt.Fprintf(&buffer, "%s = %s\n", key, s.sections[section][key])
		}
		buffer.WriteByte('\n')
	}
	return buffer.String(), nil
}

var _ config.Storage = (*memoryStorage)(nil)
