# Password history

## Contents

- [Add password history](#add-password-history)
- [Configure retention](#configure-retention)
- [Use shared archive storage](#use-shared-archive-storage)

## Add password history

```sh
bin/rails generate vouch:password_trackable User
bin/rails db:migrate
```

The generator adds `PasswordArchive`, the owner association, and `authenticates_with :password_trackable` to the selected credentials model. Its default concrete archive schema keeps the database relationship to that model:

```ruby
create_table :password_archives do |t|
  t.references :account, null: false, foreign_key: { to_table: :users }, index: false
  t.string :password_digest, null: false
  t.datetime :created_at, null: false
  t.index [:account_id, :created_at]
end
```

The archive owner is named `account` but references `users` in this example. New passwords are checked against the current digest and retained history.

## Configure retention

```ruby
authenticates_with :password_trackable,
  password_trackable: { history_count: 5, history_window: 1.year }
```

Vouch locks the current digest while it validates and archives a successful replacement, then prunes archives outside the window and count. Password reset uses the same model validation, so it cannot bypass history.

## Use shared archive storage

Only when several credential models intentionally share one archive table, opt into a polymorphic owner:

```sh
bin/rails generate vouch:password_trackable User --polymorphic
```

That migration uses `t.references :account, polymorphic: true, null: false` and a composite owner/time index. This is an advanced storage decision; normal single-model and account setups use the concrete foreign key above.

Use a polymorphic archive only when distinct credential classes deliberately share the same history table. It does not change the password policy; it changes how archive ownership is stored.
