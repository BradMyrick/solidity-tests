// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./Manager.sol";


contract Auction is ReentrancyGuard{
    using SafeMath for uint256;
    address public immutable manager; // The address of the owner
    address public maxBidder; // The address of the maximum bidder
    address public immutable nftAddress;  // The address of the NFT contract
    address public immutable creator; // The address of the auction creator
    uint256 public immutable endTime; // Timestamp of the end of the auction (in seconds)
    uint256 public immutable startTime; // The block timestamp which marks the start of the auction
    uint public directBuyPrice; // The price for a direct buy
    uint public startPrice; // The starting price for the auction
    uint public maxBid; // The maximum bid
    uint public immutable minIncrement; // The minimum increment for the bid
    uint public immutable tokenId; // The id of the token
    bool public isCancelled; // If the the auction is cancelled
    bool public isDirectBuy; // True if the auction ended due to direct buy
    bool public reserveMet; // True if the reserve has been met
    bool public auctionSold; // True if the auction has been sold via auction
    // 2% fee for auction manager
    uint constant public fee = 2;
    IERC721 _nft; // The NFT token
    bool public immutable buyNow; // True if the auction can be purchased directly

    struct Info{
        bool _buyNow;
        bool _reserveMet;
        uint256 _directBuy;
        address _creator;
        uint256 _highestBid;
        address _highestBidder;
        address _nftAddress;
        uint256 _tokenIds;
        uint256 _endTime;
        uint256 _startPrice;
        uint256 _minInc;
        // Auction State
        uint256 _state;
    }

    enum AuctionState { 
        OPEN,
        CANCELLED,
        ENDED,
        DIRECT_BUY,
        AUCTION_BUY
    }

    struct Bid { // A bid on an auction
        address sender;
        uint256 bid;
    }

    // Auction constructor
    constructor(address _creator,uint _endTime, bool _buyNow, uint _minIncrement,uint _directBuyPrice, uint _startPrice,address _nftAddress,uint _tokenId) {
        // zero check ints
        if(_endTime == 0 || _minIncrement == 0 || _directBuyPrice == 0 || _startPrice == 0){
            revert('Zero value provided');
        }
        creator = _creator; // The address of the auction creator
        manager = msg.sender; // The address of the manager
        buyNow = _buyNow; // True if the auction can be purchased directly
        reserveMet = false; // The auction has not met the reserve
        endTime = block.timestamp +  _endTime; // The timestamp which marks the end of the auction (now + 30 days = 30 days from now)
        startTime = block.timestamp; // The timestamp which marks the start of the auction
        minIncrement = _minIncrement; // The minimum increment for the bid
        directBuyPrice = _directBuyPrice; // The price for a direct buy
        startPrice = _startPrice; // The starting price for the auction
        _nft = IERC721(_nftAddress); // The address of the nft token
        nftAddress = _nftAddress;
        tokenId = _tokenId; // The id of the token
        maxBidder = _creator; // Setting the maxBidder to auction creator.

    }


    // get info about the auction
    function getInfo() external view returns (Info memory) {
        Info memory info = Info(
            buyNow,
            reserveMet,
            directBuyPrice,
            creator,
            maxBid,
            maxBidder,
            nftAddress,
            tokenId,
            endTime,
            startPrice,
            minIncrement,
            uint256(getAuctionState())

        );
        return info;
    }

    // Place a bid on the auction
    function placeBid() payable external nonReentrant() returns(bool){
        require(msg.sender != creator, "Can't bid on your own item"); // The auction creator can not place a bid
        require(getAuctionState() == AuctionState.OPEN, "Auction has closed"); // The auction must be open
        require(msg.value >= startPrice, "Bid must be at least the starting price"); // The bid must be higher than the starting price
        require(msg.value >= maxBid + minIncrement || msg.value == directBuyPrice, "Bid too low, increase increment amount or Direct Buy"); // The bid must be higher than the current max bid plus the minimum increment or the bid must be equal to the direct buy price
        address lastHightestBidder = maxBidder; // The address of the last highest bidder
        uint256 lastHighestBid = maxBid; // The last highest bid
        maxBid = msg.value; // The new highest bid
        maxBidder = msg.sender; // The address of the new highest bidder
        emit NewBid(msg.sender,msg.value); // emit a new bid event
        if (msg.value >= directBuyPrice){ // If the bid is higher than the direct buy price
            if (buyNow){ // If the auction can be purchased directly
                isDirectBuy = true; // The auction has ended
                // notify the manager
                notifyStateChange();
                emit NFTWithdrawn(maxBidder); // Emit a withdraw token event
                uint256 _fee = maxBid.mul(fee).div(100); // Calculate the fee
                emit FundsWithdrawn(creator,maxBid - _fee); // Emit a withdraw funds event
                payable(creator).transfer(maxBid - _fee); // Transfers funds to the creator
                _nft.transferFrom(address(this), maxBidder, tokenId); // Transfer the token to the highest bidder
            }
            else{ reserveMet = true; } // The reserve price has been met.
        }
        if(lastHighestBid != 0){ // if there is a bid
            payable(lastHightestBidder).transfer(lastHighestBid); // refund the previous bid to the previous highest bidder
        }
        return true; // The bid was placed successfully
    }


    function cancelAuction() external nonReentrant() returns(bool){ // Cancel the auction
        require(msg.sender == creator); // Only the auction creator can cancel the auction
        require(getAuctionState() == AuctionState.OPEN); // The auction must be open
        isCancelled = true; // The auction has been cancelled
        emit AuctionCanceled(address(this)); // Emit Auction Canceled event
        // notify the manager
        notifyStateChange();
        if(maxBid != 0){ // If there is a bid return the bid to the highest bidder
            payable(maxBidder).transfer(maxBid);
            }
        _nft.transferFrom(address(this), creator, tokenId); // Transfer the NFT token back to the auction creator
        
        return true;
    } 

    // Get the auction state
    function getAuctionState() public view returns(AuctionState) {
        if(isCancelled) return AuctionState.CANCELLED; // If the auction is cancelled return CANCELLED
        if(isDirectBuy) return AuctionState.DIRECT_BUY; // If the auction is ended by a direct buy return DIRECT_BUY
        if(auctionSold) return AuctionState.AUCTION_BUY; // If the auction finalized return SOLD
        if(block.timestamp >= endTime) return AuctionState.ENDED; // The auction is over if the block timestamp is greater than the end timestamp, return ENDED
        return AuctionState.OPEN; // Otherwise return OPEN
    } 

    function endAuction() external nonReentrant() returns(bool){ // End the auction
        require(getAuctionState() == AuctionState.ENDED, "Auction must be ended"); // The auction must be ended
        if (!reserveMet){ // If the reserve has not been met
            isCancelled = true; // The auction has been cancelled
            emit AuctionCanceled(address(this)); // Emit Auction Canceled event
            if(maxBid != 0){ // If there is a bid return the bid to the highest bidder
                payable(maxBidder).transfer(maxBid);
            }
            _nft.transferFrom(address(this), creator, tokenId); // Transfer the NFT token to the auction creator
        }
        else{ // If the reserve has been met
            auctionSold = true; // The auction has been sold
            _nft.transferFrom(address(this), maxBidder, tokenId); // Transfer the NFT token to the auction creator
            uint256 _fee = maxBid.mul(fee).div(100); // Calculate the fee
            emit FundsWithdrawn(creator,maxBid - _fee); // Emit a withdraw funds event
            payable(creator).transfer(maxBid - _fee); // Transfers funds to the creator
        }
        notifyStateChange();
        return true;
    }

    // lower reserve
    function lowerReserve(uint _reserve) external nonReentrant() returns(uint)
    {
        require(msg.sender == creator, "Creator only"); // Only the auction creator can lower the reserve
        require(_reserve <= directBuyPrice, "Reserve must be less than or equal to the current reserve price"); // The new reserve must be less than or equal to the current reserve price
        require(getAuctionState() == AuctionState.OPEN, "Auction must be open"); // The auction must be open
        directBuyPrice = _reserve; // The new direct buy (reserve) price
        if (directBuyPrice <= maxBid){ // If the direct buy price is now lower than the current bid
            reserveMet = true; // The reserve has been met
        }
        emit loweredReserve(_reserve); // Emit Lower Reserve event
        return directBuyPrice;
    }

    function notifyStateChange() internal {
        uint256 state = uint256(getAuctionState());
        AuctionManager(manager).auctionStateChanged(state);
    }

    // can't transfer fee at the same time as the auction funds to creator
    // allow the manager to transfer the fee
    function transferFee(address _to) external payable returns(bool _success) {
        require(msg.sender == manager, "Manager only"); // Only the manager can transfer the fee
        // requrie the auction isCancelled, auctionSold, or isDirectBuy
        require(getAuctionState() == AuctionState.CANCELLED || getAuctionState() == AuctionState.AUCTION_BUY || getAuctionState() == AuctionState.DIRECT_BUY, "Auction must be cancelled, sold, or direct buy"); 
        payable(_to).transfer(address(this).balance); // Transfer the fee to the address
        return true;
    }

    event loweredReserve(uint indexed _reserve); // Event for lowering the reserve
    event NewBid(address indexed bidder, uint indexed bid); // A new bid was placed
    event NFTWithdrawn(address indexed withdrawer); // The auction winner withdrew the token
    event FundsWithdrawn(address indexed withdrawer, uint256 indexed amount); // The auction owner withdrew the funds
    event AuctionCanceled(address  _auction); // The auction was cancelled

}