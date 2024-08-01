//! @title: English Auction Contract
//! @author: Simeon Cholakov (https://x.com/cholakovv)
//! @notice: Manages the creation, bidding, and withdrawal of assets in an English auction system, ensuring accurate and secure transactions.
contract;

mod errors;
mod data_structures;
mod events;
mod interface;

// use ::data_structures::{auction::Auction, state::State};
use ::data_structures::auction::Auction;
use ::data_structures::state::State;
use ::errors::{AccessError, InitError, InputError, UserError};
use ::events::{BidEvent, CancelAuctionEvent, CreateAuctionEvent, WithdrawEvent};
use ::interface::{EnglishAuction, Info};
use std::{
    asset::transfer,
    block::height,
    call_frames::msg_asset_id,
    context::msg_amount,
    hash::Hash,
};

storage {
    // Stores the auction information based on auction ID.
    // Map(auction id => auction)
    auctions: StorageMap<u64, Auction> = StorageMap {},
    // The total number of auctions that have ever been created.
    total_auctions: u64 = 0,
}

// Constants for extension mechanism
const EXTENSION_THRESHOLD: u32 = 5; // Number of blocks before the end within which a bid will trigger an extension
const EXTENSION_DURATION: u32 = 5; // Number of blocks to extend the auction if a bid is placed within the threshold
impl EnglishAuction for Contract {
    // Place a bid on an auction
    //
    // @param auction_id The ID of the auction to bid on
    #[payable]
    #[storage(read, write)] // This attribute indicates that the function reads from and writes to storage.
    fn bid(auction_id: u64) {
        // Retrieve the auction with the specified auction_id from storage
        let auction = storage.auctions.get(auction_id).try_read();
        // Check if the auction exists
        require(auction.is_some(), InputError::AuctionDoesNotExist);

        let mut auction = auction.unwrap();

        // Retrieves the sender's address and bid information
        let sender = msg_sender().unwrap();
        let bid_asset = msg_asset_id();
        let bid_amount = msg_amount();

        // Ensure the sender is not the auction seller
        require(sender != auction.seller, UserError::BidderIsSeller);
        // 1. Checks if the auction is open
        // 2. Compare the auction's end block (the block height at which the auction is supposed to end) with the current block height, ensuring that the auction is still within its active period.
        require(
            auction
                .state == State::Open && auction
                .end_block >= height(), //height() == block height ->  the number of blocks in the chain between the first block in the blockchain and the current block
            AccessError::AuctionIsNotOpen,
        );
        // Verify that the bid asset matches the asset required by the auction
        require(
            bid_asset == auction
                .bid_asset,
            InputError::IncorrectAssetProvided,
        );

        // Combine the user's previous deposits and the current bid for the total deposits to the auction the user has made
        let total_bid = match auction.deposits.get(&sender) { // The & symbol is used to create a reference to a value. A reference allows you to borrow a value without taking ownership of it.
            Some(sender_deposit) => bid_amount + sender_deposit, // If the user has previous deposits, add them to the current bid
            None => bid_amount, // If no previous deposits, use the current bid amount
        };

        // Ensure the total bid meets or exceeds the auction's initial price.
        require(
            total_bid >= auction
                .initial_price,
            InputError::InitialPriceNotMet,
        );

        // Check that the total bid is higher than the current highest bid
        require(
            total_bid > auction
                .highest_bid,
            InputError::IncorrectAmountProvided,
        );

        // Check if reserve has been met if there is one set
        if auction.reserve_price.is_some() {
            let reserve_price = auction.reserve_price.unwrap();

            // Ensure the total bid does not exceed the reserve price
            require(
                reserve_price >= total_bid,
                InputError::IncorrectAmountProvided,
            );

            // If the total bid equals the reserve price, the auction is closed
            if reserve_price == total_bid {
                auction.state = State::Closed;
            }
        }

        // Check if the bid is placed within the extension threshold
        if auction.end_block - height() <= EXTENSION_THRESHOLD {
            // If the bid is placed within the last few blocks of the auction duration (defined by EXTENSION_THRESHOLD),
            // we extend the auction duration to allow other bidders a chance to respond.
            // This helps prevent sniping, where someone places a bid at the last moment without giving others a fair chance.
            auction.end_block += EXTENSION_DURATION; // Extend the auction end block by the defined EXTENSION_DURATION
        }

        // Update the auction's information and store the new state
        auction.highest_bidder = Option::Some(sender); // Option::Some(sender): Option is a type that can either hold a value (Some) or be empty (None). Here, it wraps the sender (the current bidder's address) in a Some to indicate that there is a new highest bidder
        auction.highest_bid = total_bid;
        auction.deposits.insert(sender, total_bid); // insert(sender, total_bid): This method updates the deposits map by setting the value for the sender key to total_bid
        storage.auctions.insert(auction_id, auction); // This line saves the updated auction object back to storage, ensuring that all changes made (highest bidder, highest bid, deposits) are persisted in the blockchain
        log(BidEvent {
            amount: auction.highest_bid,
            auction_id: auction_id,
            user: sender,
        });
    }

    // Cancel an auction
    //
    // @param auction_id The ID of the auction to cancel
    #[storage(read, write)] // This attribute indicates that the function reads from and writes to storage.
    fn cancel(auction_id: u64) {
        // Retrieve the auction with the specified auction_id from storage.
        let auction = storage.auctions.get(auction_id).try_read();
        // Ensure the auction exists. If not, throw an error.
        require(auction.is_some(), InputError::AuctionDoesNotExist);

        let mut auction = auction.unwrap();

        // Ensure the auction is still open and has not ended
        require(
            // Check if the auction state is 'Open' and the current block height is less than the auction's end block.
            auction
                .state == State::Open && auction
                .end_block >= height(),
            AccessError::AuctionIsNotOpen,
        );

        // Ensure the sender is the seller of the auction
        require(
            // Check if the sender of the message is the seller of the auction.
            msg_sender()
                .unwrap() == auction
                .seller,
            AccessError::SenderIsNotSeller,
        );

        // Update and store the auction's information
        // Reset the highest bidder to None.
        auction.highest_bidder = Option::None;
        // Change the auction state to Closed.
        auction.state = State::Closed;
        // Save the updated auction back to storage.
        storage.auctions.insert(auction_id, auction);

        log(CancelAuctionEvent { auction_id });
    }

    // Create a new auction
    //
    // @param bid_asset The asset used for bidding
    // @param duration The duration of the auction in blocks
    // @param initial_price The initial price for the auction
    // @param reserve_price The reserve price for the auction (optional)
    // @param seller The identity of the seller
    // @return The ID of the created auction
    #[payable]
    #[storage(read, write)] // This attribute indicates that the function reads from and writes to storage.
    fn create(
        bid_asset: AssetId,
        duration: u32,
        initial_price: u64,
        reserve_price: Option<u64>,
        seller: Identity,
    ) -> u64 {
        // Either there is no reserve price or the reserve must be greater than the initial price
        require(
            reserve_price
                .is_none() || (reserve_price
                    .is_some() && reserve_price
                    .unwrap() > initial_price),
            InitError::ReserveLessThanInitialPrice,
        );
        // Ensure the duration is not zero.
        require(duration != 0, InitError::AuctionDurationNotProvided);
        // Ensure the initial price is not zero.
        require(initial_price != 0, InitError::InitialPriceCannotBeZero);

        // Retrieve the asset being sold from the message context.
        let sell_asset = msg_asset_id();
        // Retrieve the amount of the asset being sold from the message context.
        let sell_asset_amount = msg_amount();
        // Ensure the amount of the selling asset is not zero.
        require(sell_asset_amount != 0, InputError::IncorrectAmountProvided);

        // Setup auction
        let auction = Auction::new(
            bid_asset, // The asset used for bidding.
            duration + height(), // The end block of the auction, calculated as the current block height plus the duration.
            initial_price, // The starting price of the auction.
            reserve_price, // The reserve price, if any.
            sell_asset, // The asset being sold.
            sell_asset_amount, // The amount of the selling asset.
            seller, // The identity of the seller.
        );

        // Store the auction information
        let total_auctions = storage.total_auctions.read();
        // Insert the new auction into the storage map with the current total as the key.
        storage.auctions.insert(total_auctions, auction);
        // Increment the total number of auctions by 1 and write it back to storage.
        storage.total_auctions.write(total_auctions + 1);

        log(CreateAuctionEvent {
            auction_id: total_auctions,
            bid_asset,
            sell_asset,
            sell_asset_amount,
        });

        total_auctions
    }

    // Withdraw from an auction
    //
    // @param auction_id The ID of the auction to withdraw from
    #[storage(read, write)] // This attribute indicates that the function reads from and writes to storage.
    fn withdraw(auction_id: u64) {
        // Make sure this auction exists
        let auction = storage.auctions.get(auction_id).try_read();
        // Ensure the auction exists. If not, throw an error.
        require(auction.is_some(), InputError::AuctionDoesNotExist);

        // Cannot withdraw if the auction is still on going
        let mut auction = auction.unwrap();
        // Check if the auction state is 'Closed' or the current block height is greater than or equal to the auction's end block.
        require(
            auction
                .state == State::Closed || auction
                .end_block <= height(),
            AccessError::AuctionIsNotClosed,
        );

        // If the auction has ended but is still marked as 'Open', close it
        if auction.end_block <= height() && auction.state == State::Open {
            // Change the auction state to Closed.
            auction.state = State::Closed;
            // Save the updated auction back to storage.
            storage.auctions.insert(auction_id, auction);
        }

        let sender = msg_sender().unwrap();
        let bidder = auction.highest_bidder;
        // Retrieve the deposit amount of the sender using a reference to the sender.
        let sender_deposit = auction.deposits.get(&sender); // The & symbol is used to create a reference to a value. A reference allows you to borrow a value without taking ownership of it.

        // Ensure the sender has a deposit to withdraw
        require(sender_deposit.is_some(), UserError::UserHasAlreadyWithdrawn);
        // Remove the sender's deposit from the auction using a reference to the sender.
        auction.deposits.remove(&sender); // The & symbol is used to create a reference to a value. A reference allows you to borrow a value without taking ownership of it.
        let mut withdrawn_amount = *sender_deposit.unwrap(); // The * symbol is used for dereferencing. Dereferencing a reference gives you access to the value that the reference points to.
        let mut withdrawn_asset = auction.bid_asset;

        // Withdraw owed assets based on the sender's role (winner, seller, or other bidders)
        if (bidder.is_some() && sender == bidder.unwrap()) || (bidder.is_none() && sender == auction.seller) {
            // Winning bidder or seller withdraws original sold assets
            // Transfer the sell asset to the sender.
            transfer(sender, auction.sell_asset, auction.sell_asset_amount);
            // Update the withdrawn asset type to the sell asset.
            withdrawn_asset = auction.sell_asset;
            // Update the withdrawn amount to the sell asset amount.
            withdrawn_amount = auction.sell_asset_amount;
        } else if sender == auction.seller {
            // Seller withdraws winning bids
            // Transfer the highest bid amount to the seller.
            transfer(sender, auction.bid_asset, auction.highest_bid);
            // Update the withdrawn amount to the highest bid amount.
            withdrawn_amount = auction.highest_bid;
        } else {
            // Bidders withdraw failed bids
            // Transfer the bid asset back to the bidder.
            transfer(sender, withdrawn_asset, withdrawn_amount);
        }

        log(WithdrawEvent {
            asset: withdrawn_asset,
            asset_amount: withdrawn_amount,
            auction_id,
            user: sender,
        });
    }
}

impl Info for Contract {
    // Retrieve auction information
    //
    // @param auction_id The ID of the auction
    // @return The auction information, if it exists
    #[storage(read)] // This attribute indicates that the function reads from storage.
    fn auction_info(auction_id: u64) -> Option<Auction> {
        storage.auctions.get(auction_id).try_read() // Attempt to retrieve the auction with the given auction_id from storage. Returns Some(Auction) if found, otherwise None.
    }

    // Retrieve deposit balance for a user
    //
    // @param auction_id The ID of the auction
    // @param identity The identity of the user
    // @return The deposit balance, if it exists
    #[storage(read)] // This attribute indicates that the function reads from storage.
    fn deposit_balance(auction_id: u64, identity: Identity) -> Option<u64> {
        let auction = storage.auctions.get(auction_id).try_read(); // Retrieve the auction with the specified auction_id from storage.
        match auction { // Match on the result of the retrieval.
            Some(auction) => auction.deposits.get(&identity).copied(), // If the auction exists, get the user's deposit and return a copy of it.
            None => None, // If the auction does not exist, return None.
        }
    }

    // Retrieve the total number of auctions
    //
    // @return The total number of auctions
    #[storage(read)] // This attribute indicates that the function reads from storage.
    fn total_auctions() -> u64 {
        storage.total_auctions.read() // Read and return the total number of auctions from storage.
    }
}
