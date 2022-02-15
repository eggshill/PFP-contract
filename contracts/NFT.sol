// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./ERC721AUpgradeable.sol";
import "./interfaces/IMerkleDistributor.sol";
import "./utils/VRFConsumerBaseUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/MerkleProofUpgradeable.sol";

contract NFT is
    VRFConsumerBaseUpgradeable,
    OwnableUpgradeable,
    ERC721AUpgradeable,
    ReentrancyGuardUpgradeable,
    IMerkleDistributor
{
    using StringsUpgradeable for uint256;

    uint256 public constant AUCTION_START_PRICE = 1 ether;
    uint256 public constant AUCTION_END_PRICE = 0.15 ether;
    uint256 public constant AUCTION_PRICE_CURVE_LENGTH = 340 minutes;
    uint256 public constant AUCTION_DROP_INTERVAL = 20 minutes;
    uint256 public constant AUCTION_DROP_PER_STEP =
        (AUCTION_START_PRICE - AUCTION_END_PRICE) / (AUCTION_PRICE_CURVE_LENGTH / AUCTION_DROP_INTERVAL);

    uint256 public maxPerAddressDuringMint;
    uint256 public amountForDevs;
    // uint256 public amountForAuctionAndDev;
    bytes32 public override merkleRoot;
    bytes32 public _keyHash;

    bool public _revealed;
    uint256 public _randomResult;
    uint256 public _startingIndex;
    bool public _isUriFrozen;
    uint256 public _fee;

    // // metadata URI
    string private _baseTokenURI;
    string private _notRevealedURI;

    struct SaleConfig {
        uint32 auctionSaleStartTime;
        uint32 publicSaleStartTime;
        uint64 mintlistPrice;
        uint64 publicPrice;
        uint32 publicSaleKey;
    }

    SaleConfig public saleConfig;

    // mapping(address => uint256) public allowlist;

    function initialize(
        string memory name_,
        string memory symbol_,
        string memory contractURI_,
        uint256 maxBatchSize_,
        uint256 collectionSize_,
        // uint256 amountForAuctionAndDev_,
        uint256 amountForDevs_,
        address vrfCoordinatorAddress_,
        address linkAddress_,
        bytes32 keyHash_,
        uint256 fee_
    ) public initializer {
        __Context_init_unchained();
        __ERC165_init_unchained();
        __VRFConsumerBase_init(vrfCoordinatorAddress_, linkAddress_);
        __ERC721A_init_unchained(name_, symbol_, contractURI_, maxBatchSize_, collectionSize_);

        maxPerAddressDuringMint = maxBatchSize_;
        // amountForAuctionAndDev = amountForAuctionAndDev_;
        amountForDevs = amountForDevs_;
        // require(amountForAuctionAndDev_ <= collectionSize_, "larger collection size needed");

        _keyHash = keyHash_;
        _fee = fee_;
    }

    modifier callerIsUser() {
        require(tx.origin == msg.sender, "The caller is another contract");
        _;
    }

    // function allowlistMint() external payable callerIsUser {
    //     uint256 price = uint256(saleConfig.mintlistPrice);
    //     require(price != 0, "allowlist sale has not begun yet");
    //     require(allowlist[msg.sender] > 0, "not eligible for allowlist mint");
    //     require(totalSupply() + 1 <= collectionSize, "reached max supply");
    //     allowlist[msg.sender]--;
    //     _safeMint(msg.sender, 1);
    //     refundIfOver(price);
    // }

    function preSalesMint(
        uint256 index,
        address account,
        uint256 quantity,
        bytes32[] calldata merkleProof
    ) external payable override callerIsUser {
        uint256 price = uint256(saleConfig.mintlistPrice);
        require(price != 0, "allowlist sale has not begun yet");
        // require(allowlist[msg.sender] > 0, "not eligible for allowlist mint");
        require(totalSupply() + quantity <= collectionSize, "reached max supply");
        require(numberMinted(msg.sender) + quantity <= maxPerAddressDuringMint, "can not mint this many");

        // Verify the merkle proof.
        bytes32 node = keccak256(abi.encodePacked(index, account));
        // bytes32 node = keccak256(abi.encodePacked(index, account, quantity));
        require(MerkleProofUpgradeable.verify(merkleProof, merkleRoot, node), "MerkleDistributor: Invalid proof.");

        // Mark it claimed and send the token.
        // _setClaimed(index);
        // allowlist[msg.sender]--;
        _safeMint(msg.sender, quantity);
        refundIfOver(price);

        emit Claimed(index, account, quantity);
    }

    function publicSaleMint(uint256 quantity, uint256 callerPublicSaleKey) external payable callerIsUser {
        SaleConfig memory config = saleConfig;
        uint256 publicSaleKey = uint256(config.publicSaleKey);
        uint256 publicPrice = uint256(config.publicPrice);
        uint256 publicSaleStartTime = uint256(config.publicSaleStartTime);
        require(publicSaleKey == callerPublicSaleKey, "called with incorrect public sale key");

        require(isPublicSaleOn(publicPrice, publicSaleKey, publicSaleStartTime), "public sale has not begun yet");
        require(totalSupply() + quantity <= collectionSize, "reached max supply");
        require(numberMinted(msg.sender) + quantity <= maxPerAddressDuringMint, "can not mint this many");
        _safeMint(msg.sender, quantity);
        refundIfOver(publicPrice * quantity);
    }

    function auctionMint(uint256 quantity) external payable callerIsUser {
        uint256 _saleStartTime = uint256(saleConfig.auctionSaleStartTime);
        require(_saleStartTime != 0 && block.timestamp >= _saleStartTime, "sale has not started yet");
        require(totalSupply() + quantity <= collectionSize, "reached max supply");
        require(numberMinted(msg.sender) + quantity <= maxPerAddressDuringMint, "can not mint this many");
        uint256 totalCost = getAuctionPrice(_saleStartTime) * quantity;
        _safeMint(msg.sender, quantity);
        refundIfOver(totalCost);
    }

    function refundIfOver(uint256 price) private {
        require(msg.value >= price, "Need to send more ETH.");
        if (msg.value > price) {
            (bool success, ) = payable(msg.sender).call{value: msg.value - price}("");
            require(success, "Failed to send Ether");
        }
    }

    function isPublicSaleOn(
        uint256 publicPriceWei,
        uint256 publicSaleKey,
        uint256 publicSaleStartTime
    ) public view returns (bool) {
        return publicPriceWei != 0 && publicSaleKey != 0 && block.timestamp >= publicSaleStartTime;
    }

    function getAuctionPrice(uint256 _saleStartTime) public view returns (uint256) {
        if (block.timestamp < _saleStartTime) {
            return AUCTION_START_PRICE;
        }
        if (block.timestamp - _saleStartTime >= AUCTION_PRICE_CURVE_LENGTH) {
            return AUCTION_END_PRICE;
        } else {
            uint256 steps = (block.timestamp - _saleStartTime) / AUCTION_DROP_INTERVAL;
            return AUCTION_START_PRICE - (steps * AUCTION_DROP_PER_STEP);
        }
    }

    function setMaxPerAddressDuringMint(uint32 quantity) external onlyOwner {
        maxPerAddressDuringMint = quantity;
    }

    function endAuctionAndSetupNonAuctionSaleInfo(
        uint64 mintlistPriceWei,
        uint64 publicPriceWei,
        uint32 publicSaleStartTime
    ) external onlyOwner {
        saleConfig = SaleConfig(0, publicSaleStartTime, mintlistPriceWei, publicPriceWei, saleConfig.publicSaleKey);
    }

    function setAuctionSaleStartTime(uint32 timestamp) external onlyOwner {
        saleConfig.auctionSaleStartTime = timestamp;
    }

    function setPublicSaleKey(uint32 key) external onlyOwner {
        saleConfig.publicSaleKey = key;
    }

    // function seedAllowlist(address[] memory addresses, uint256[] memory numSlots) external onlyOwner {
    //     require(addresses.length == numSlots.length, "addresses does not match numSlots length");
    //     for (uint256 i = 0; i < addresses.length; i++) {
    //         allowlist[addresses[i]] = numSlots[i];
    //     }
    // }

    // For marketing etc.
    function devMint(uint256 quantity) external onlyOwner {
        require(totalSupply() + quantity <= amountForDevs, "too many already minted before dev mint");
        require(quantity % maxBatchSize == 0, "can only mint a multiple of the maxBatchSize");
        uint256 numChunks = quantity / maxBatchSize;
        for (uint256 i = 0; i < numChunks; i++) {
            _safeMint(msg.sender, maxBatchSize);
        }
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return _baseTokenURI;
    }

    function setBaseURI(string calldata baseURI) external onlyOwner {
        require(!_isUriFrozen, "Token URI is frozen");
        _baseTokenURI = baseURI;
    }

    function setNotRevealedURI(string calldata notRevealedURI) external onlyOwner {
        _notRevealedURI = notRevealedURI;
    }

    function freezeTokenURI() external onlyOwner {
        require(!_isUriFrozen, "Token URI is frozen");
        _isUriFrozen = true;
    }

    function reveal() external onlyOwner {
        require(!_revealed, "Already revealed");
        require(_startingIndex == 0, "Already set Starting index");

        require(LINK.balanceOf(address(this)) >= _fee, "Not enough LINK");
        requestRandomness(_keyHash, _fee);

        // _revealed = true;
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");

        if (_revealed == false) {
            return _notRevealedURI;
        }

        require(_startingIndex != 0, "randomness request hasn't finalized");

        string memory baseURI = _baseURI();
        return
            bytes(baseURI).length != 0
                ? string(abi.encodePacked(baseURI, ((tokenId + _startingIndex) % collectionSize).toString()))
                : "default token uri?";
    }

    /**
     * Callback function used by VRF Coordinator
     */
    function fulfillRandomness(bytes32 requestId, uint256 randomness) internal virtual override {
        _startingIndex = (randomness % collectionSize);

        // Prevent default sequence
        if (_startingIndex == 0) {
            unchecked {
                _startingIndex = _startingIndex + 1;
            }
        }

        _revealed = true;
    }

    function withdrawMoney() external nonReentrant {
        (bool success, ) = owner().call{value: address(this).balance}("");
        require(success, "Transfer failed.");
    }

    function numberMinted(address owner) public view returns (uint256) {
        return _numberMinted(owner);
    }

    function getOwnershipData(uint256 tokenId) external view returns (TokenOwnership memory) {
        return ownershipOf(tokenId);
    }
}