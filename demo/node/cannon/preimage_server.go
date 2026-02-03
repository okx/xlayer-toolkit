package cannon

import (
	"context"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"sync"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// PreimageKeyType represents the type of preimage key.
type PreimageKeyType byte

const (
	LocalKeyType      PreimageKeyType = 1
	Keccak256KeyType  PreimageKeyType = 2
	Sha256KeyType     PreimageKeyType = 4
	BlobKeyType       PreimageKeyType = 5
	PrecompileKeyType PreimageKeyType = 6
)

// PreimageServer serves preimage requests from cannon.
// It implements the preimage oracle protocol used by cannon.
type PreimageServer struct {
	mu        sync.RWMutex
	preimages map[common.Hash][]byte
	logger    *log.Logger

	// For hint handling
	hintHandler func(hint string) error
}

// NewPreimageServer creates a new preimage server.
func NewPreimageServer(logger *log.Logger) *PreimageServer {
	if logger == nil {
		logger = log.New(os.Stderr, "[PreimageServer] ", log.LstdFlags)
	}
	return &PreimageServer{
		preimages:   make(map[common.Hash][]byte),
		logger:      logger,
		hintHandler: func(hint string) error { return nil }, // no-op by default
	}
}

// SetHintHandler sets the hint handler function.
func (s *PreimageServer) SetHintHandler(handler func(hint string) error) {
	s.hintHandler = handler
}

// AddPreimage adds a preimage with its keccak256 key.
func (s *PreimageServer) AddPreimage(data []byte) common.Hash {
	hash := crypto.Keccak256Hash(data)
	// Set type byte to keccak256
	key := hash
	key[0] = byte(Keccak256KeyType)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.preimages[key] = data
	s.logger.Printf("Added keccak256 preimage: key=%s len=%d", hex.EncodeToString(key[:8]), len(data))
	return key
}

// AddLocalData adds local data with a specific identifier.
func (s *PreimageServer) AddLocalData(ident uint64, data []byte) common.Hash {
	var key common.Hash
	key[0] = byte(LocalKeyType)
	binary.BigEndian.PutUint64(key[24:], ident)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.preimages[key] = data
	s.logger.Printf("Added local preimage: ident=%d key=%s len=%d", ident, hex.EncodeToString(key[:8]), len(data))
	return key
}

// GetPreimage retrieves a preimage by key.
func (s *PreimageServer) GetPreimage(key [32]byte) ([]byte, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	k := common.Hash(key)
	data, ok := s.preimages[k]
	if !ok {
		return nil, fmt.Errorf("preimage not found: %s", hex.EncodeToString(key[:]))
	}
	return data, nil
}

// Clear removes all preimages.
func (s *PreimageServer) Clear() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.preimages = make(map[common.Hash][]byte)
}

// ServePreimageRequests serves preimage requests on the given ReadWriter.
// This implements the protocol expected by cannon's OracleClient.
func (s *PreimageServer) ServePreimageRequests(ctx context.Context, rw io.ReadWriter) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		// Read 32-byte key
		var key [32]byte
		if _, err := io.ReadFull(rw, key[:]); err != nil {
			if err == io.EOF {
				return nil // Normal termination
			}
			return fmt.Errorf("failed to read preimage key: %w", err)
		}

		s.logger.Printf("Preimage request: key=%s", hex.EncodeToString(key[:8]))

		// Get preimage
		value, err := s.GetPreimage(key)
		if err != nil {
			s.logger.Printf("Preimage not found: %s", hex.EncodeToString(key[:]))
			// Return empty response
			if err := binary.Write(rw, binary.BigEndian, uint64(0)); err != nil {
				return fmt.Errorf("failed to write empty length: %w", err)
			}
			continue
		}

		// Write length prefix
		if err := binary.Write(rw, binary.BigEndian, uint64(len(value))); err != nil {
			return fmt.Errorf("failed to write length prefix: %w", err)
		}

		// Write value
		if len(value) > 0 {
			if _, err := rw.Write(value); err != nil {
				return fmt.Errorf("failed to write preimage value: %w", err)
			}
		}

		s.logger.Printf("Served preimage: key=%s len=%d", hex.EncodeToString(key[:8]), len(value))
	}
}

// ServeHintRequests serves hint requests on the given ReadWriter.
// This implements the protocol expected by cannon's HintWriter.
func (s *PreimageServer) ServeHintRequests(ctx context.Context, rw io.ReadWriter) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		// Read 4-byte length prefix
		var length uint32
		if err := binary.Read(rw, binary.BigEndian, &length); err != nil {
			if err == io.EOF {
				return nil // Normal termination
			}
			return fmt.Errorf("failed to read hint length: %w", err)
		}

		// Read hint payload
		payload := make([]byte, length)
		if length > 0 {
			if _, err := io.ReadFull(rw, payload); err != nil {
				return fmt.Errorf("failed to read hint payload: %w", err)
			}
		}

		hint := string(payload)
		s.logger.Printf("Hint received: %s", hint)

		// Handle hint
		if err := s.hintHandler(hint); err != nil {
			s.logger.Printf("Hint handler error: %v", err)
		}

		// Write ack byte
		if _, err := rw.Write([]byte{0}); err != nil {
			return fmt.Errorf("failed to write hint ack: %w", err)
		}
	}
}

// PreimageServerProcess manages the preimage server as file descriptors for cannon.
type PreimageServerProcess struct {
	server *PreimageServer
	logger *log.Logger

	// Pipes for communication with cannon
	hintReaderPipe     *os.File // cannon writes hints here
	hintWriterPipe     *os.File // we read hints from here
	preimageReaderPipe *os.File // cannon writes preimage requests here
	preimageWriterPipe *os.File // we read preimage requests from here

	// For cleanup
	cancel context.CancelFunc
	wg     sync.WaitGroup
}

// NewPreimageServerProcess creates a new preimage server process.
func NewPreimageServerProcess(server *PreimageServer, logger *log.Logger) (*PreimageServerProcess, error) {
	if logger == nil {
		logger = log.New(os.Stderr, "[PreimageServerProcess] ", log.LstdFlags)
	}

	return &PreimageServerProcess{
		server: server,
		logger: logger,
	}, nil
}

// CreatePipes creates the pipes for communication with cannon.
// Returns the file descriptors that should be passed to cannon as ExtraFiles.
func (p *PreimageServerProcess) CreatePipes() ([]*os.File, error) {
	// Create hint pipes
	hintRead, hintWrite, err := os.Pipe()
	if err != nil {
		return nil, fmt.Errorf("failed to create hint pipe: %w", err)
	}

	// Create hint response pipes
	hintRespRead, hintRespWrite, err := os.Pipe()
	if err != nil {
		hintRead.Close()
		hintWrite.Close()
		return nil, fmt.Errorf("failed to create hint response pipe: %w", err)
	}

	// Create preimage request pipes
	preimageRead, preimageWrite, err := os.Pipe()
	if err != nil {
		hintRead.Close()
		hintWrite.Close()
		hintRespRead.Close()
		hintRespWrite.Close()
		return nil, fmt.Errorf("failed to create preimage request pipe: %w", err)
	}

	// Create preimage response pipes
	preimageRespRead, preimageRespWrite, err := os.Pipe()
	if err != nil {
		hintRead.Close()
		hintWrite.Close()
		hintRespRead.Close()
		hintRespWrite.Close()
		preimageRead.Close()
		preimageWrite.Close()
		return nil, fmt.Errorf("failed to create preimage response pipe: %w", err)
	}

	// Store our ends of the pipes
	p.hintReaderPipe = hintRead
	p.hintWriterPipe = hintRespWrite
	p.preimageReaderPipe = preimageRead
	p.preimageWriterPipe = preimageRespWrite

	// Return cannon's ends of the pipes
	// Order: hint_read, hint_write, preimage_read, preimage_write
	return []*os.File{
		hintRespRead,     // fd 3: cannon reads hint responses
		hintWrite,        // fd 4: cannon writes hints
		preimageRespRead, // fd 5: cannon reads preimage responses
		preimageWrite,    // fd 6: cannon writes preimage requests
	}, nil
}

// Start starts the preimage server goroutines.
func (p *PreimageServerProcess) Start(ctx context.Context) error {
	ctx, p.cancel = context.WithCancel(ctx)

	// Start hint handler
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		p.serveHints(ctx)
	}()

	// Start preimage handler
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		p.servePreimages(ctx)
	}()

	return nil
}

func (p *PreimageServerProcess) serveHints(ctx context.Context) {
	rw := &pipeReadWriter{
		reader: p.hintReaderPipe,
		writer: p.hintWriterPipe,
	}
	if err := p.server.ServeHintRequests(ctx, rw); err != nil && ctx.Err() == nil {
		p.logger.Printf("Hint server error: %v", err)
	}
}

func (p *PreimageServerProcess) servePreimages(ctx context.Context) {
	rw := &pipeReadWriter{
		reader: p.preimageReaderPipe,
		writer: p.preimageWriterPipe,
	}
	if err := p.server.ServePreimageRequests(ctx, rw); err != nil && ctx.Err() == nil {
		p.logger.Printf("Preimage server error: %v", err)
	}
}

// Stop stops the preimage server.
func (p *PreimageServerProcess) Stop() {
	if p.cancel != nil {
		p.cancel()
	}
	p.wg.Wait()

	// Close pipes
	if p.hintReaderPipe != nil {
		p.hintReaderPipe.Close()
	}
	if p.hintWriterPipe != nil {
		p.hintWriterPipe.Close()
	}
	if p.preimageReaderPipe != nil {
		p.preimageReaderPipe.Close()
	}
	if p.preimageWriterPipe != nil {
		p.preimageWriterPipe.Close()
	}
}

// pipeReadWriter combines separate read and write pipes into an io.ReadWriter.
type pipeReadWriter struct {
	reader *os.File
	writer *os.File
}

func (p *pipeReadWriter) Read(b []byte) (int, error) {
	return p.reader.Read(b)
}

func (p *pipeReadWriter) Write(b []byte) (int, error) {
	return p.writer.Write(b)
}

// TCPPreimageServer serves preimage requests over TCP (for debugging).
type TCPPreimageServer struct {
	server   *PreimageServer
	listener net.Listener
	logger   *log.Logger
}

// NewTCPPreimageServer creates a TCP preimage server.
func NewTCPPreimageServer(server *PreimageServer, addr string, logger *log.Logger) (*TCPPreimageServer, error) {
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("failed to listen on %s: %w", addr, err)
	}

	if logger == nil {
		logger = log.New(os.Stderr, "[TCPPreimageServer] ", log.LstdFlags)
	}

	return &TCPPreimageServer{
		server:   server,
		listener: listener,
		logger:   logger,
	}, nil
}

// Addr returns the server's address.
func (s *TCPPreimageServer) Addr() string {
	return s.listener.Addr().String()
}

// Serve starts serving connections.
func (s *TCPPreimageServer) Serve(ctx context.Context) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		conn, err := s.listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			s.logger.Printf("Accept error: %v", err)
			continue
		}

		go func() {
			defer conn.Close()
			if err := s.server.ServePreimageRequests(ctx, conn); err != nil {
				s.logger.Printf("Connection error: %v", err)
			}
		}()
	}
}

// Close closes the server.
func (s *TCPPreimageServer) Close() error {
	return s.listener.Close()
}
