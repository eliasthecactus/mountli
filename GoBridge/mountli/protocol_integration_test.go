package mountli

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/pkg/sftp"
	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/config/obscure"
	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
	"golang.org/x/net/webdav"
)

func TestLoopbackWebDAVRoundTrip(t *testing.T) {
	Shutdown()
	root := t.TempDir()
	const username = "mountli-test"
	const password = "loopback-only-password"

	var methodsMu sync.Mutex
	methods := map[string]int{}
	var rangedDownloads atomic.Int64
	handler := &webdav.Handler{
		Prefix:     "/",
		FileSystem: webdav.Dir(root),
		LockSystem: webdav.NewMemLS(),
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		providedUser, providedPassword, ok := request.BasicAuth()
		if !ok || providedUser != username || providedPassword != password {
			response.Header().Set("WWW-Authenticate", `Basic realm="MOUNTLI loopback fixture"`)
			http.Error(response, "authentication required", http.StatusUnauthorized)
			return
		}
		methodsMu.Lock()
		methods[request.Method]++
		methodsMu.Unlock()
		if request.Header.Get("Range") != "" {
			rangedDownloads.Add(1)
		}
		handler.ServeHTTP(response, request)
	}))
	t.Cleanup(server.Close)

	certificatePath := filepath.Join(t.TempDir(), "webdav-root.pem")
	certificate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})
	if err := os.WriteFile(certificatePath, certificate, 0o600); err != nil {
		t.Fatal(err)
	}
	config := fs.GetConfig(baseContext)
	originalCACerts := append([]string(nil), config.CaCert...)
	config.CaCert = []string{certificatePath}
	t.Cleanup(func() {
		Shutdown()
		config.CaCert = originalCACerts
	})

	obscuredPassword, err := obscure.Obscure(password)
	if err != nil {
		t.Fatal(err)
	}
	runProtocolRoundTrip(t, "loopback-webdav", "webdav", map[string]string{
		"url":    server.URL,
		"vendor": "other",
		"user":   username,
		"pass":   obscuredPassword,
	})

	methodsMu.Lock()
	defer methodsMu.Unlock()
	for _, method := range []string{"MKCOL", "PUT", "PROPFIND", "GET", "MOVE", "DELETE"} {
		if methods[method] == 0 {
			t.Errorf("WebDAV fixture did not observe %s; methods = %#v", method, methods)
		}
	}
	if rangedDownloads.Load() == 0 {
		t.Error("WebDAV fixture did not observe a validated ranged download")
	}
}

type normalizedSFTPHandler struct {
	handlers sftp.Handlers
}

func newNormalizedSFTPHandlers() sftp.Handlers {
	handler := &normalizedSFTPHandler{handlers: sftp.InMemHandler()}
	return sftp.Handlers{FileGet: handler, FilePut: handler, FileCmd: handler, FileList: handler}
}

func normalizedSFTPRequest(request *sftp.Request) *sftp.Request {
	normalized := sftp.NewRequest(request.Method, normalizedSFTPPath(request.Filepath))
	normalized.Flags = request.Flags
	normalized.Attrs = request.Attrs
	if request.Target != "" {
		normalized.Target = normalizedSFTPPath(request.Target)
	}
	return normalized
}

func normalizedSFTPPath(value string) string {
	return path.Clean("/" + strings.TrimPrefix(value, "/"))
}

func (handler *normalizedSFTPHandler) Fileread(request *sftp.Request) (io.ReaderAt, error) {
	return handler.handlers.FileGet.Fileread(normalizedSFTPRequest(request))
}

func (handler *normalizedSFTPHandler) Filewrite(request *sftp.Request) (io.WriterAt, error) {
	return handler.handlers.FilePut.Filewrite(normalizedSFTPRequest(request))
}

func (handler *normalizedSFTPHandler) OpenFile(request *sftp.Request) (sftp.WriterAtReaderAt, error) {
	return handler.handlers.FilePut.(sftp.OpenFileWriter).OpenFile(normalizedSFTPRequest(request))
}

func (handler *normalizedSFTPHandler) Filecmd(request *sftp.Request) error {
	return handler.handlers.FileCmd.Filecmd(normalizedSFTPRequest(request))
}

func (handler *normalizedSFTPHandler) PosixRename(request *sftp.Request) error {
	return handler.handlers.FileCmd.(sftp.PosixRenameFileCmder).PosixRename(normalizedSFTPRequest(request))
}

func (handler *normalizedSFTPHandler) Filelist(request *sftp.Request) (sftp.ListerAt, error) {
	return handler.handlers.FileList.Filelist(normalizedSFTPRequest(request))
}

func (handler *normalizedSFTPHandler) Lstat(request *sftp.Request) (sftp.ListerAt, error) {
	return handler.handlers.FileList.(sftp.LstatFileLister).Lstat(normalizedSFTPRequest(request))
}

func (handler *normalizedSFTPHandler) RealPath(value string) (string, error) {
	return normalizedSFTPPath(value), nil
}

func (handler *normalizedSFTPHandler) Readlink(value string) (string, error) {
	return handler.handlers.FileList.(sftp.ReadlinkFileLister).Readlink(normalizedSFTPPath(value))
}

type sftpFixture struct {
	listener        net.Listener
	serverConfig    *ssh.ServerConfig
	connectionsMu   sync.Mutex
	connections     map[net.Conn]struct{}
	handlers        sftp.Handlers
	waitGroup       sync.WaitGroup
	authentications atomic.Int64
	sessions        atomic.Int64
}

func newSFTPFixture(t *testing.T) (*sftpFixture, map[string]string) {
	t.Helper()
	_, hostPrivateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	hostSigner, err := ssh.NewSignerFromKey(hostPrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	_, clientPrivateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	clientSigner, err := ssh.NewSignerFromKey(clientPrivateKey)
	if err != nil {
		t.Fatal(err)
	}

	fixture := &sftpFixture{
		connections: map[net.Conn]struct{}{},
		handlers:    newNormalizedSFTPHandlers(),
	}
	fixture.serverConfig = &ssh.ServerConfig{
		PublicKeyCallback: func(metadata ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			if metadata.User() != "mountli-test" || !bytes.Equal(key.Marshal(), clientSigner.PublicKey().Marshal()) {
				return nil, fmt.Errorf("unauthorized SSH key")
			}
			fixture.authentications.Add(1)
			return nil, nil
		},
	}
	fixture.serverConfig.AddHostKey(hostSigner)
	fixture.listener, err = net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	fixture.waitGroup.Add(1)
	go fixture.accept()
	t.Cleanup(fixture.Close)

	host, port, err := net.SplitHostPort(fixture.listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	credentialDirectory := t.TempDir()
	privateKeyBlock, err := ssh.MarshalPrivateKey(clientPrivateKey, "MOUNTLI loopback fixture")
	if err != nil {
		t.Fatal(err)
	}
	privateKeyPath := filepath.Join(credentialDirectory, "client-key")
	if err := os.WriteFile(privateKeyPath, pem.EncodeToMemory(privateKeyBlock), 0o600); err != nil {
		t.Fatal(err)
	}
	knownHostsPath := filepath.Join(credentialDirectory, "known-hosts")
	knownHostAddress := fmt.Sprintf("[%s]:%s", host, port)
	knownHostLine := knownhosts.Line([]string{knownHostAddress}, hostSigner.PublicKey()) + "\n"
	if err := os.WriteFile(knownHostsPath, []byte(knownHostLine), 0o600); err != nil {
		t.Fatal(err)
	}
	return fixture, map[string]string{
		"host":              host,
		"port":              port,
		"user":              "mountli-test",
		"key_file":          privateKeyPath,
		"known_hosts_file":  knownHostsPath,
		"disable_hashcheck": "true",
	}
}

func (fixture *sftpFixture) accept() {
	defer fixture.waitGroup.Done()
	for {
		connection, err := fixture.listener.Accept()
		if err != nil {
			return
		}
		fixture.connectionsMu.Lock()
		fixture.connections[connection] = struct{}{}
		fixture.connectionsMu.Unlock()
		fixture.waitGroup.Add(1)
		go fixture.serve(connection)
	}
}

func (fixture *sftpFixture) serve(connection net.Conn) {
	defer fixture.waitGroup.Done()
	defer func() {
		_ = connection.Close()
		fixture.connectionsMu.Lock()
		delete(fixture.connections, connection)
		fixture.connectionsMu.Unlock()
	}()
	serverConnection, channels, requests, err := ssh.NewServerConn(connection, fixture.serverConfig)
	if err != nil {
		return
	}
	defer serverConnection.Close()
	go ssh.DiscardRequests(requests)
	for channelRequest := range channels {
		if channelRequest.ChannelType() != "session" {
			_ = channelRequest.Reject(ssh.UnknownChannelType, "session channels only")
			continue
		}
		channel, channelRequests, err := channelRequest.Accept()
		if err != nil {
			return
		}
		fixture.waitGroup.Add(1)
		go fixture.serveChannel(channel, channelRequests)
	}
}

func (fixture *sftpFixture) serveChannel(channel ssh.Channel, requests <-chan *ssh.Request) {
	defer fixture.waitGroup.Done()
	defer channel.Close()
	for request := range requests {
		var subsystem struct{ Name string }
		if request.Type != "subsystem" || ssh.Unmarshal(request.Payload, &subsystem) != nil || subsystem.Name != "sftp" {
			_ = request.Reply(false, nil)
			continue
		}
		_ = request.Reply(true, nil)
		fixture.sessions.Add(1)
		server := sftp.NewRequestServer(channel, fixture.handlers)
		err := server.Serve()
		_ = server.Close()
		if err != nil && err != io.EOF {
			return
		}
		return
	}
}

func (fixture *sftpFixture) Close() {
	if fixture.listener == nil {
		return
	}
	_ = fixture.listener.Close()
	fixture.connectionsMu.Lock()
	for connection := range fixture.connections {
		_ = connection.Close()
	}
	fixture.connectionsMu.Unlock()
	fixture.waitGroup.Wait()
	fixture.listener = nil
}

func TestLoopbackSFTPRoundTrip(t *testing.T) {
	Shutdown()
	fixture, options := newSFTPFixture(t)
	t.Cleanup(Shutdown)
	runProtocolRoundTrip(t, "loopback-sftp", "sftp", options)
	if fixture.authentications.Load() == 0 {
		t.Error("SFTP fixture did not authenticate the generated client key")
	}
	if fixture.sessions.Load() == 0 {
		t.Error("SFTP fixture did not serve an SFTP subsystem session")
	}
}

func runProtocolRoundTrip(t *testing.T, engineName, backendType string, options map[string]string) {
	t.Helper()
	optionsJSON, err := json.Marshal(options)
	if err != nil {
		t.Fatal(err)
	}
	requireSuccess(t, ValidateConfiguration(backendType, string(optionsJSON), ""))
	vaultJSON, err := json.Marshal(vaultPayload{
		SchemaVersion: schemaVersion,
		Remotes: []remotePayload{{
			EngineName:  engineName,
			BackendType: backendType,
			Options:     options,
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := LoadVault(string(vaultJSON)); err != nil {
		t.Fatal(err)
	}

	temporaryDirectory := t.TempDir()
	const contents = "MOUNTLI validates real loopback protocol I/O"
	sourcePath := filepath.Join(temporaryDirectory, "source.txt")
	secondSourcePath := filepath.Join(temporaryDirectory, "second.txt")
	if err := os.WriteFile(sourcePath, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(secondSourcePath, []byte("second object"), 0o600); err != nil {
		t.Fatal(err)
	}

	requireSuccess(t, MakeDirectory(engineName+"-mkdir", engineName, "fixture"))
	requireSuccess(t, Upload(engineName+"-upload", engineName, "fixture/hello.txt", sourcePath, ""))
	requireSuccess(t, Upload(engineName+"-upload-second", engineName, "fixture/second.txt", secondSourcePath, ""))

	listing := requireSuccess(t, List(engineName, "fixture", "", 500))
	listingJSON, err := json.Marshal(listing.Data)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(listingJSON), "hello.txt") || !strings.Contains(string(listingJSON), "second.txt") {
		t.Fatalf("protocol listing = %s", listingJSON)
	}

	partialPath := filepath.Join(temporaryDirectory, "partial.txt")
	requireSuccess(t, Download(engineName+"-range", engineName, "fixture/hello.txt", "", partialPath, 8, 9))
	partial, err := os.ReadFile(partialPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(partial) != 17 || string(partial[8:]) != contents[8:17] {
		t.Fatalf("ranged protocol download = %q (length %d)", partial, len(partial))
	}
	for index, value := range partial[:8] {
		if value != 0 {
			t.Fatalf("ranged protocol byte %s = %d, want sparse zero", strconv.Itoa(index), value)
		}
	}

	requireSuccess(t, Move(engineName+"-move", engineName, "fixture/hello.txt", "", "fixture/renamed.txt", "", ""))
	fullPath := filepath.Join(temporaryDirectory, "full.txt")
	requireSuccess(t, Download(engineName+"-download", engineName, "fixture/renamed.txt", "", fullPath, 0, 0))
	full, err := os.ReadFile(fullPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(full) != contents {
		t.Fatalf("full protocol download = %q", full)
	}
	requireSuccess(t, Delete(engineName+"-delete", engineName, "fixture/renamed.txt", "", ""))
	requireSuccess(t, Delete(engineName+"-delete-second", engineName, "fixture/second.txt", "", ""))
}
