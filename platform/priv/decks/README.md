# Card decks

Classic #1, Syndicate #1, Cascade #1 and Accelerant #1 each have a deck of 1,000
cards, made before the fleet was created. Keys 1 to 1,000 of those fleets each
show one card from their fleet's deck; Keys 1,001 onward, and every other
fleet, draw their own card from their own seed. With this rule, the fleet's
reveals on chain and the deck file, anyone can work out every Key's card.

## A deck file

`<deck hash>.json`, where the deck hash is `keccak256` of the file's bytes
exactly as they are. The fleet's record on chain holds that hash and the
number of cards, fixed when the fleet was created.

```json
{"fleet": "CLASSIC #1", "table": "0x…", "cards": ["0x…", "0x…", …]}
```

Cards are numbered from 0 in the order listed. A card is a 32-byte seed; its
eight traits are the ones the trait table `table` (in `../trait_tables`) gives
that seed, by the same draw every Key uses.

## Which card a Key gets

1. Take the fleet's reveals of Keys numbered 1 to the deck's size, in the order
   they were logged on chain: by block number, then by log index within the
   block. Each Key is revealed once, with its seed.
2. Start with the remaining cards `0, 1, 2, …, size − 1`, in that order.
3. For each reveal in turn, read its seed as a 256-bit unsigned number and let
   `n` be how many cards remain. The Key gets the card at position
   `seed mod n` in the remaining list, counting from 0. The last card in the
   list then moves into that position, and the list is one shorter.

No card is dealt twice, and the 1,000th Key gets the last card left.

## Example

A deck of 10 cards and seeds `keccak256("deal-1")` to `keccak256("deal-10")`,
revealed in that order, deals cards `2, 6, 8, 5, 1, 4, 3, 7, 9, 0`.
The site's own copy of the rule is `Keyfleet.Decks.deal/2`.
