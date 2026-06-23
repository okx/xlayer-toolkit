// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Generic, dependency-free devnet test mocks. Not tied to any one feature —
// reusable by any devnet manual test that needs a token, a value forwarder, a
// selfdestruct sink, or a revert-swallowing inner caller. NOT production code.

/// Forwards its msg.value to `t` via a low-level call. Top-level `to` is this
/// contract, so the inner transfer is what hits any execution-time check.
contract ValueForwarder {
    function forward(address payable t) external payable {
        (bool ok, ) = t.call{value: msg.value}("");
        ok;
    }
}

/// Minimal ERC20 (canonical Transfer/Approval events), with an open `mint` for
/// test setup. Standard selectors (transfer/transferFrom/approve).
contract MockERC20 {
    string public name = "MockERC20";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
        emit Transfer(address(0), to, v);
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        emit Transfer(msg.sender, to, v);
        return true;
    }

    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[to] += v;
        emit Transfer(f, to, v);
        return true;
    }

    /// Emit a Transfer whose from/to are the same arbitrary address (not the
    /// subject under test) — useful for "event present but parties don't match"
    /// negative checks.
    function noise(address anyone) external {
        emit Transfer(anyone, anyone, uint256(uint160(msg.sender)));
    }
}

/// Minimal ERC1155 emitting TransferSingle (a different event shape than the
/// ERC20 Transfer — different topic layout).
contract MockERC1155 {
    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 value
    );
    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] values
    );

    function move(address from, address to, uint256 id, uint256 v) external {
        emit TransferSingle(msg.sender, from, to, id, v);
    }

    function moveBatch(address from, address to, uint256[] calldata ids, uint256[] calldata values) external {
        emit TransferBatch(msg.sender, from, to, ids, values);
    }
}

/// Transfers its balance to `b` via selfdestruct. Post-Cancun (EIP-6780) this
/// only moves the ether unless created in the same tx — the ether still reaches
/// the beneficiary.
contract SelfDestructor {
    function destroyTo(address payable b) external payable {
        selfdestruct(b);
    }
}

/// Makes an inner call that may revert, and swallows the revert so the outer tx
/// still succeeds. Used to test that effects in a reverted sub-frame are NOT
/// treated as committed.
contract CallSwallower {
    function swallow(address t, bytes calldata data) external payable {
        (bool ok, ) = t.call{value: msg.value}(data);
        ok; // swallow: outer tx succeeds regardless
    }
}

/// Minimal ERC721. ERC721's Transfer event topic0 is identical to ERC20's
/// (keccak256("Transfer(address,address,uint256)")), so a Transfer-event based
/// check hits this the same way as an ERC20 transfer.
contract MockERC721 {
    mapping(uint256 => address) public ownerOf;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    function mint(address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == address(0), "exists");
        ownerOf[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not owner");
        ownerOf[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }
}
