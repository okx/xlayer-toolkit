package cannon

import (
	"github.com/ethereum/go-ethereum/common"
)

// VMState represents the MIPS VM state.
type VMState struct {
	MemRoot        common.Hash    `json:"memRoot"`
	PreimageKey    common.Hash    `json:"preimageKey"`
	PreimageOffset uint64         `json:"preimageOffset"`
	PC             uint64         `json:"pc"`
	NextPC         uint64         `json:"nextPC"`
	Lo             uint64         `json:"lo"`
	Hi             uint64         `json:"hi"`
	Heap           uint64         `json:"heap"`
	ExitCode       uint8          `json:"exitCode"`
	Exited         bool           `json:"exited"`
	Step           uint64         `json:"step"`
	Registers      [32]uint64     `json:"registers"`
}

// VMStatus represents the VM execution status.
type VMStatus uint8

const (
	VMStatusValid      VMStatus = 0 // Exited with code 0
	VMStatusInvalid    VMStatus = 1 // Exited with code 1
	VMStatusPanic      VMStatus = 2 // Exited with code > 1
	VMStatusUnfinished VMStatus = 3 // Not exited
)

// String returns the string representation of the VM status.
func (s VMStatus) String() string {
	switch s {
	case VMStatusValid:
		return "Valid"
	case VMStatusInvalid:
		return "Invalid"
	case VMStatusPanic:
		return "Panic"
	case VMStatusUnfinished:
		return "Unfinished"
	default:
		return "Unknown"
	}
}

// StateHash computes the hash of the VM state with status byte.
func (s *VMState) StateHash() common.Hash {
	// Encode state
	data := s.Encode()
	
	// Compute hash
	hash := common.BytesToHash(data)
	
	// Set status byte
	var status VMStatus
	if s.Exited {
		switch s.ExitCode {
		case 0:
			status = VMStatusValid
		case 1:
			status = VMStatusInvalid
		default:
			status = VMStatusPanic
		}
	} else {
		status = VMStatusUnfinished
	}
	
	// Replace high byte with status
	hashBytes := hash.Bytes()
	hashBytes[0] = byte(status)
	
	return common.BytesToHash(hashBytes)
}

// Encode encodes the VM state to bytes.
func (s *VMState) Encode() []byte {
	data := make([]byte, 0, 444) // 188 + 256 bytes
	
	// Fixed fields
	data = append(data, s.MemRoot.Bytes()...)
	data = append(data, s.PreimageKey.Bytes()...)
	data = append(data, uint64ToBytes(s.PreimageOffset)...)
	data = append(data, uint64ToBytes(s.PC)...)
	data = append(data, uint64ToBytes(s.NextPC)...)
	data = append(data, uint64ToBytes(s.Lo)...)
	data = append(data, uint64ToBytes(s.Hi)...)
	data = append(data, uint64ToBytes(s.Heap)...)
	data = append(data, s.ExitCode)
	if s.Exited {
		data = append(data, 1)
	} else {
		data = append(data, 0)
	}
	data = append(data, uint64ToBytes(s.Step)...)
	
	// Registers
	for i := 0; i < 32; i++ {
		data = append(data, uint64ToBytes(s.Registers[i])...)
	}
	
	return data
}

// Decode decodes the VM state from bytes.
func (s *VMState) Decode(data []byte) error {
	if len(data) < 444 {
		return ErrInvalidStateData
	}
	
	offset := 0
	
	copy(s.MemRoot[:], data[offset:offset+32])
	offset += 32
	
	copy(s.PreimageKey[:], data[offset:offset+32])
	offset += 32
	
	s.PreimageOffset = bytesToUint64(data[offset : offset+8])
	offset += 8
	
	s.PC = bytesToUint64(data[offset : offset+8])
	offset += 8
	
	s.NextPC = bytesToUint64(data[offset : offset+8])
	offset += 8
	
	s.Lo = bytesToUint64(data[offset : offset+8])
	offset += 8
	
	s.Hi = bytesToUint64(data[offset : offset+8])
	offset += 8
	
	s.Heap = bytesToUint64(data[offset : offset+8])
	offset += 8
	
	s.ExitCode = data[offset]
	offset += 1
	
	s.Exited = data[offset] != 0
	offset += 1
	
	s.Step = bytesToUint64(data[offset : offset+8])
	offset += 8
	
	for i := 0; i < 32; i++ {
		s.Registers[i] = bytesToUint64(data[offset : offset+8])
		offset += 8
	}
	
	return nil
}

// Helper functions
func uint64ToBytes(v uint64) []byte {
	b := make([]byte, 8)
	for i := 0; i < 8; i++ {
		b[7-i] = byte(v >> (i * 8))
	}
	return b
}

func bytesToUint64(b []byte) uint64 {
	var v uint64
	for i := 0; i < 8; i++ {
		v = (v << 8) | uint64(b[i])
	}
	return v
}
