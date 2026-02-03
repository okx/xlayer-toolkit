package cannon

import "errors"

var (
	// ErrInvalidStateData is returned when the state data is invalid.
	ErrInvalidStateData = errors.New("invalid state data")
	
	// ErrPreimageNotFound is returned when a preimage is not found.
	ErrPreimageNotFound = errors.New("preimage not found")
	
	// ErrInvalidPreimageKey is returned when a preimage key is invalid.
	ErrInvalidPreimageKey = errors.New("invalid preimage key")
	
	// ErrVMPanic is returned when the VM panics.
	ErrVMPanic = errors.New("VM panic")
	
	// ErrVMInvalid is returned when the VM exits with invalid status.
	ErrVMInvalid = errors.New("VM invalid")
	
	// ErrMaxStepsExceeded is returned when the maximum number of steps is exceeded.
	ErrMaxStepsExceeded = errors.New("max steps exceeded")
)
