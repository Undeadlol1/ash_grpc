# Bulk calls

A bulk call creates, updates or destroys many records in one request. Turn it
on per rpc:

    rpc Post, :create_posts, :create, bulk?: true, args: [title: 1]
    rpc Post, :archive_posts, :archive, bulk?: true, args: [id: 1]
    rpc Post, :delete_posts, :destroy, bulk?: true, args: [id: 1]

`bulk?` works on create, update and destroy actions. It cannot be combined with
`clear_fields` or the paging options.

## Requests

- A bulk create takes `repeated <Rpc>Input inputs = 1`. Each input holds the
  action's fields, so every record can differ.
- A bulk update or destroy takes `repeated ids = 1`, then the action's inputs
  once. Every listed record gets the same inputs. A composite primary key becomes
  a repeated `<Rpc>Key` message.

The response is `repeated result = 1`.

## All or nothing

The whole call runs in one transaction. If any record fails, nothing is saved.
This needs a data layer that supports transactions, such as AshPostgres.

## Limits

`max_bulk_size` (default 100) caps the list. A longer list answers
INVALID_ARGUMENT before anything runs:

    rpc Post, :create_posts, :create, bulk?: true, max_bulk_size: 500, args: [title: 1]

An empty list answers an empty result.

## What comes back

- Ids that do not exist, or that the caller may not see, are absent from the
  result. They are not an error.
- An error names the item: `inputs[2].title`.
- `response_meta` works as on a list call, once for the whole response.

For many messages on one open call, see [Streaming calls](streaming-calls.md).
