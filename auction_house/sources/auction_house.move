#[allow(duplicate_alias, unused_variable)]
module auction_house::auction {
    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::vec_map::{Self, VecMap};
    use sui::clock::{Self, Clock};
    use sui::event;
    use std::option;
    use std::vector;

    // Constants
    const MAX_FEE_PERCENTAGE: u64 = 1000; // 10%
    const MIN_AUCTION_DURATION: u64 = 3600000; // 1 hour in ms

    // Errors
    const EAUCTION_ENDED: u64 = 0;
    const EAUCTION_NOT_STARTED: u64 = 1;
    const EBID_TOO_LOW: u64 = 2;
    const EINVALID_FEE: u64 = 3;
    const EINVALID_DURATION: u64 = 4;

    // Structs
    public struct AuctionHouse has key {
        id: UID,
        fee_percentage: u64,
        fee_recipient: address,
        auctions: VecMap<ID, Auction>,
        whitelisted_collections: vector<address>,
        is_whitelist_enabled: bool,
    }

    public struct Auction has key, store {
        id: UID,
        seller: address,
        highest_bid: u64,
        highest_bidder: address,
        start_time: u64,
        end_time: u64,
        min_bid: u64,
        bid_increment: u64,
        item: Coin<0x2::sui::SUI>,
        ended: bool,
        bids: vector<Bid>,
        buy_now_price: option::Option<u64>,
    }

    public struct Bid has copy, drop, store {
        bidder: address,
        amount: u64,
        timestamp: u64,
    }

    // Events
    public struct AuctionCreated has copy, drop {
        auction_id: ID,
        seller: address,
        item_id: ID,
        start_time: u64,
        end_time: u64,
        buy_now_price: option::Option<u64>,
    }

    public struct BidPlaced has copy, drop {
        auction_id: ID,
        bidder: address,
        amount: u64,
    }

    public struct AuctionEnded has copy, drop {
        auction_id: ID,
        winner: address,
        amount: u64,
    }

    public struct BuyNowExecuted has copy, drop {
        auction_id: ID,
        buyer: address,
        price: u64,
    }

    public struct CollectionWhitelisted has copy, drop {
        collection_id: ID,
    }

    // Initialization
    public fun initialize(
        fee_percentage: u64,
        fee_recipient: address,
        ctx: &mut TxContext
    ): AuctionHouse {
        assert!(fee_percentage <= MAX_FEE_PERCENTAGE, EINVALID_FEE);

        AuctionHouse {
            id: object::new(ctx),
            fee_percentage,
            fee_recipient,
            auctions: vec_map::empty(),
            whitelisted_collections: vector::empty(),
            is_whitelist_enabled: false,
        }
    }

    // Auction Creation
    public entry fun create_auction(
        auction_house: &mut AuctionHouse,
        item: Coin<0x2::sui::SUI>,
        duration: u64,
        min_bid: u64,
        bid_increment: u64,
        buy_now_price: option::Option<u64>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(duration >= MIN_AUCTION_DURATION, EINVALID_DURATION);

        let current_time = clock::timestamp_ms(clock);
        let end_time = current_time + duration;

        let auction = Auction {
            id: object::new(ctx),
            seller: tx_context::sender(ctx),
            highest_bid: 0,
            highest_bidder: @0x0,
            start_time: current_time,
            end_time,
            min_bid,
            bid_increment,
            item,
            ended: false,
            bids: vector::empty(),
            buy_now_price,
        };

        let auction_id = object::id(&auction);
        vec_map::insert(&mut auction_house.auctions, auction_id, auction);

        event::emit(AuctionCreated {
            auction_id,
            seller: tx_context::sender(ctx),
            item_id: object::id(&item),
            start_time: current_time,
            end_time,
            buy_now_price,
        });
    }

    // Bidding
    public entry fun place_bid(
        auction_house: &mut AuctionHouse,
        auction_id: ID,
        bid: Coin<0x2::sui::SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let auction = vec_map::get_mut(&mut auction_house.auctions, &auction_id);

        assert!(!auction.ended, EAUCTION_ENDED);
        assert!(current_time >= auction.start_time, EAUCTION_NOT_STARTED);
        assert!(current_time <= auction.end_time, EAUCTION_ENDED);

        let bid_amount = coin::value(&bid);
        let min_required_bid = if (auction.highest_bid == 0) {
            auction.min_bid
        } else {
            auction.highest_bid + auction.bid_increment
        };

        assert!(bid_amount >= min_required_bid, EBID_TOO_LOW);

        vector::push_back(&mut auction.bids, Bid {
            bidder: tx_context::sender(ctx),
            amount: bid_amount,
            timestamp: current_time,
        });

        if (bid_amount > auction.highest_bid) {
            auction.highest_bid = bid_amount;
            auction.highest_bidder = tx_context::sender(ctx);
        };

        event::emit(BidPlaced {
            auction_id,
            bidder: tx_context::sender(ctx),
            amount: bid_amount,
        });
    }

    // Buy Now
    public entry fun buy_now(
        auction_house: &mut AuctionHouse,
        auction_id: ID,
        mut payment: Coin<0x2::sui::SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let auction = vec_map::get_mut(&mut auction_house.auctions, &auction_id);
        let buy_now_price = option::extract(&mut auction.buy_now_price);

        assert!(coin::value(&payment) == buy_now_price, EBID_TOO_LOW);
        assert!(!auction.ended, EAUCTION_ENDED);

        auction.ended = true;
        auction.highest_bid = buy_now_price;
        auction.highest_bidder = tx_context::sender(ctx);

        let fee_amount = buy_now_price * auction_house.fee_percentage / 10000;
        let seller_amount = buy_now_price - fee_amount;

        if (fee_amount > 0) {
            let fee_coin = coin::split(&mut payment, fee_amount, ctx);
            transfer::public_transfer(fee_coin, auction_house.fee_recipient);
        };

        transfer::public_transfer(payment, auction.seller);

        event::emit(BuyNowExecuted {
            auction_id,
            buyer: tx_context::sender(ctx),
            price: buy_now_price,
        });
    }

    // End Auction
    public entry fun end_auction(
        auction_house: &mut AuctionHouse,
        auction_id: ID,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let auction = vec_map::get_mut(&mut auction_house.auctions, &auction_id);

        assert!(current_time > auction.end_time, EAUCTION_NOT_STARTED);
        assert!(!auction.ended, EAUCTION_ENDED);

        auction.ended = true;

        event::emit(AuctionEnded {
            auction_id,
            winner: auction.highest_bidder,
            amount: auction.highest_bid,
        });
    }

    // Admin
    public entry fun set_fee_percentage(
        auction_house: &mut AuctionHouse,
        new_fee: u64,
        _: &TxContext
    ) {
        assert!(new_fee <= MAX_FEE_PERCENTAGE, EINVALID_FEE);
        auction_house.fee_percentage = new_fee;
    }

    public entry fun toggle_whitelist(
        auction_house: &mut AuctionHouse,
        _: &TxContext
    ) {
        auction_house.is_whitelist_enabled = !auction_house.is_whitelist_enabled;
    }

    public entry fun whitelist_collection(
        auction_house: &mut AuctionHouse,
        collection_id: ID,
        _: &TxContext
    ) {
        vector::push_back(
            &mut auction_house.whitelisted_collections, 
            object::id_to_address(&collection_id)
        );
        event::emit(CollectionWhitelisted { collection_id });
    }
}