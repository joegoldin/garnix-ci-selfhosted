# Database Migrations

Migrations are handled with [Sqitch](https://sqitch.org/).

## general setup

Create a file `~/.sqitch/sqitch.conf` containing something like the following:

```toml
[user]
email = foo@example.com
name = Foo B. Baz
```

## creating a database change

**NB**: `sqitch` currently needs to be run from the sql directory, but when it’s run as part of the `db` script, it uses a wrapper that avoids that issue, but is also what requires updating `direnv` when we switch branches (although updating `direnv` is probably a good habit to get into).

```sh
cd sql
sqitch add --change name_of_change
```

This will add an entry to [./sqitch.plan](./sqitch.plan) for your new change and create three template files to be populated:

- ./deploy/name_of_change.sql
- ./revert/name_of_change.sql
- ./verify/name_of_change.sql

The “deploy” file should contain SQL statements to make the change to an existing database; the“revert” file should contain SQL statements to undo the change to the database; and the “verify” file should contain SQL statements to check that the change was done correctly.
