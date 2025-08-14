#[allow(duplicate_alias, unused_variable)]
module auction_house::nft {
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::event;
    use sui::vec_map::{Self, VecMap};
    use sui::tx_context::{Self, TxContext};
    use std::string::String;
    use std::vector;

    // Errors
    const ENotCollectionOwner: u64 = 0;
    const ECollectionNotExists: u64 = 1;
    const EAttributesMismatch: u64 = 2;

    // Structs
    public struct Collection has key {
        id: UID,
        name: String,
        description: String,
        creator: address,
        nfts: VecMap<ID, NFT>,
        symbol: String,
        total_supply: u64,
    }

    public struct NFT has key, store{
        id: UID,
        collection_id: ID,
        name: String,
        description: String,
        image_url: String,
        attributes: VecMap<String, String>,
        token_id: u64,
    }

    // Events
    public struct CollectionCreated has copy, drop {
        collection_id: ID,
        name: String,
        creator: address,
    }

    public struct NFTCreated has copy, drop {
        nft_id: ID,
        collection_id: ID,
        name: String,
        token_id: u64,
    }

    public struct NFTTransferred has copy, drop {
        nft_id: ID,
        from: address,
        to: address,
    }

    public struct NFTBurned has copy, drop {
        nft_id: ID,
        collection_id: ID,
    }

    // Functions
    public fun create_collection(
        name: String,
        description: String,
        symbol: String,
        ctx: &mut TxContext
    ): Collection {
        let collection = Collection {
            id: object::new(ctx),
            name,
            description,
            creator: tx_context::sender(ctx),
            nfts: vec_map::empty(),
            symbol,
            total_supply: 0,
        };

        event::emit(CollectionCreated {
            collection_id: object::id(&collection),
            name: copy name,
            creator: collection.creator,
        });

        collection
    }

    public fun mint_nft(
        collection: &mut Collection,
        name: String,
        description: String,
        image_url: String,
        attributes: vector<String>,
        attribute_values: vector<String>,
        ctx: &mut TxContext
    ): NFT {
        assert!(tx_context::sender(ctx) == collection.creator, ENotCollectionOwner);
        assert!(vector::length(&attributes) == vector::length(&attribute_values), EAttributesMismatch);

        let token_id = collection.total_supply + 1;
        collection.total_supply = token_id;

        let mut attributes_map = vec_map::empty();
        let i = 0;
        while (i < vector::length(&attributes)) {
            let key = *vector::borrow(&attributes, i);
            let value = *vector::borrow(&attribute_values, i);
            vec_map::insert(&mut attributes_map, key, value);
            i = i + 1;
        };

        let nft = NFT {
            id: object::new(ctx),
            collection_id: object::id(collection),
            name,
            description,
            image_url,
            attributes: attributes_map,
            token_id,
        };

        let nft_id = object::id(&nft);
        vec_map::insert(&mut collection.nfts, nft_id, nft);

        event::emit(NFTCreated {
            nft_id,
            collection_id: object::id(collection),
            name: copy name,
            token_id,
        });

    
    }

    public entry fun transfer_nft(
        collection: &mut Collection,
        nft_id: ID,
        recipient: address,
        ctx: &mut TxContext
    ) {
        assert!(vec_map::contains(&collection.nfts, &nft_id), ECollectionNotExists);

        let (_, nft) = vec_map::remove(&mut collection.nfts, &nft_id);
        transfer::public_transfer(nft, recipient);

        event::emit(NFTTransferred {
            nft_id,
            from: tx_context::sender(ctx),
            to: recipient,
        });
    }

    public entry fun burn_nft(
        collection: &mut Collection,
        nft_id: ID,
        ctx: &mut TxContext
    ) {
        assert!(vec_map::contains(&collection.nfts, &nft_id), ECollectionNotExists);
        let (_, nft) = vec_map::remove(&mut collection.nfts, &nft_id);
        let NFT { id, collection_id, .. } = nft;
        object::delete(id);

        event::emit(NFTBurned {
            nft_id,
            collection_id,
        });
    }
}