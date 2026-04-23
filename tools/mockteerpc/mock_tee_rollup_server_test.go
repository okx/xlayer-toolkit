package mockteerpc_test

import (
	"encoding/hex"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	mockteerpc "github.com/okx/xlayer-toolkit/tools/mockteerpc"
	"github.com/stretchr/testify/require"
)

func TestTeeRollupServer_Basic(t *testing.T) {
	srv := mockteerpc.NewTeeRollupServer(t)

	// --- first request ---
	resp, err := http.Get(srv.Addr() + "/chain/confirmed_block_info") //nolint:noctx
	require.NoError(t, err)
	defer resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode)

	var body mockteerpc.TeeRollupResponse
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&body))

	require.Equal(t, 0, body.Code)
	require.Equal(t, "OK", body.Message)
	require.GreaterOrEqual(t, body.Data.Height, uint64(1000))
	require.Equal(t, 66, len(body.Data.AppHash), "appHash should be 0x + 64 hex chars")
	require.Equal(t, 66, len(body.Data.BlockHash), "blockHash should be 0x + 64 hex chars")

	firstHeight := body.Data.Height

	// --- wait for at least one tick ---
	time.Sleep(1500 * time.Millisecond)

	resp2, err := http.Get(srv.Addr() + "/chain/confirmed_block_info") //nolint:noctx
	require.NoError(t, err)
	defer resp2.Body.Close()

	var body2 mockteerpc.TeeRollupResponse
	require.NoError(t, json.NewDecoder(resp2.Body).Decode(&body2))

	require.Greater(t, body2.Data.Height, firstHeight, "height should have increased after 1.5s")

	// --- verify CurrentInfo height is >= last observed HTTP height ---
	h, _, _ := srv.CurrentInfo()
	require.GreaterOrEqual(t, h, body2.Data.Height,
		"CurrentInfo height should be >= last HTTP response height")

	// --- verify hash determinism ---
	appHash := mockteerpc.ComputeAppHash(body2.Data.Height)
	require.Equal(t, "0x"+hex.EncodeToString(appHash[:]), body2.Data.AppHash)
	blockHash := mockteerpc.ComputeBlockHash(appHash)
	require.Equal(t, "0x"+hex.EncodeToString(blockHash[:]), body2.Data.BlockHash)
}

func TestTeeRollupServer_DoubleClose(t *testing.T) {
	srv := mockteerpc.NewTeeRollupServer(t)
	// Explicit close before t.Cleanup runs — must not panic.
	require.NotPanics(t, srv.Close)
}
