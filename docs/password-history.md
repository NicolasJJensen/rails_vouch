# Password history

Password history prevents reuse of the current password and a configurable number of previous passwords. A `PasswordArchive` row stores a previous password digest and when it was replaced; it never stores the plaintext password.

## Contents

- [Add password history](#add-password-history)
- [Change a password](#change-a-password)
- [Configure retention](#configure-retention)
- [Use shared archive storage](#use-shared-archive-storage)
- [Existing models and generator reruns](#existing-models-and-generator-reruns)

## Add password history

Start with an existing `User` model that has password authentication and a `password_digest` column.

```sh
bin/rails generate vouch:password_trackable User
bin/rails db:migrate
```

The generator:

- Creates a `PasswordArchive` model with an owner association and the Vouch archive marker.
- Creates a migration for `password_archives`.
- Enables `:password_trackable` and adds the archive association to `User`.
- Creates no controllers, views, routes or mailers.

The generated migration for an ordinary `User` uses this schema:

```ruby
# db/migrate/<timestamp>_create_password_archives.rb
class CreatePasswordArchives < ActiveRecord::Migration[8.1]
  def change
    create_table :password_archives do |t|
      t.references :user, null: false, type: :bigint,
        foreign_key: { to_table: :users }, index: false
      t.string :password_digest, null: false
      t.datetime :created_at, null: false

      t.index [:user_id, :created_at]
    end
  end
end
```

The owner/time index also covers lookups by owner, so a separate `user_id` index is unnecessary. The generated associations connect the archive to the selected model:

```ruby
# app/models/password_archive.rb
class PasswordArchive < ApplicationRecord
  include Vouch::PasswordArchive::Concern
  belongs_to :user, class_name: "User", foreign_key: :user_id, primary_key: :id
end
```

```ruby
# app/models/user.rb
class User < ApplicationRecord
  include Vouch::Authenticatable
  has_secure_password

  authenticates_with :password_trackable
  has_many :password_archives, foreign_key: :user_id, primary_key: :id,
    dependent: :destroy
end
```

If a separate model holds your passwords, generate against it instead. For example:

```sh
bin/rails generate vouch:password_trackable Account
bin/rails db:migrate
```

This uses `account_id` referencing `accounts`. The command adds history support; it does not create the password-owning model or its password fields.

## Change a password

History runs during ordinary password updates. For example, in your password settings controller:

```ruby
# app/controllers/passwords_controller.rb
class PasswordsController < AuthenticatedController
  def update
    # Authorize changes to current_user with your application's permissions.
    if current_user.update(password_params)
      redirect_to edit_password_path, notice: "Password updated"
    else
      @user = current_user
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def password_params
    params.require(:user).permit(:password, :password_confirmation)
  end
end
```

`AuthenticatedController`, the settings routes and `edit` view in this example belong to your application. Render `@user.errors` in that form. Reusing a password adds an error to `:password`. Vouch's normal [password reset](password-reset.md) operation runs the same validation.

> Validation-skipping saves, direct `password_digest` assignments, `update_columns`, `update_all` and SQL are not the supported password-change path. They can bypass reuse checks; callback-bypassing writes also skip archiving.

## Configure retention

The defaults check the current password plus up to five archived passwords replaced within the past month. Both the count and the time window apply. To retain a year of history for one model:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  include Vouch::Authenticatable
  has_secure_password

  authenticates_with :password_trackable,
    password_trackable: { history_count: 5, history_window: 1.year }
  has_many :password_archives, dependent: :destroy
end
```

- Five archives means up to five **previous** passwords, in addition to the current password.
- `history_count: 0` retains no archives, but still rejects the current password.
- Counts must be nonnegative integers; windows must be nonnegative durations. Invalid global or model settings raise `Vouch::ConfigurationError` when configured.
- Archive time is when the password was replaced, not when it was originally chosen.
- Expired and excess rows are pruned on password replacement, not by a background timer.
- The first password has no previous digest to archive.

Global defaults are available through `config.password_trackable.history_count` and `config.password_trackable.history_window`. When the model has several archive associations, select one with `password_trackable: { association: :old_passwords }`; a single matching association is inferred.

## Use shared archive storage

If different authentication models intentionally share a history table, choose polymorphic storage from the start:

```sh
bin/rails generate vouch:password_trackable User --polymorphic
bin/rails db:migrate
```

The migration uses this owner reference and index:

```ruby
# db/migrate/<timestamp>_create_password_archives.rb
class CreatePasswordArchives < ActiveRecord::Migration[8.1]
  def change
    create_table :password_archives do |t|
      t.references :owner, polymorphic: true, null: false, type: :bigint, index: false
      t.string :password_digest, null: false
      t.datetime :created_at, null: false

      t.index [:owner_type, :owner_id, :created_at]
    end
  end
end
```

```ruby
# app/models/password_archive.rb
class PasswordArchive < ApplicationRecord
  include Vouch::PasswordArchive::Concern
  belongs_to :owner, polymorphic: true
end
```

```ruby
# app/models/user.rb
class User < ApplicationRecord
  include Vouch::Authenticatable
  has_secure_password

  authenticates_with :password_trackable
  has_many :password_archives, as: :owner, dependent: :destroy
end
```

The participating models must use compatible owner-key types. Polymorphic storage has no ordinary foreign key spanning its owner tables. The generator does not support composite keys in shared polymorphic storage; use concrete storage for those owners. Concrete custom and composite owner keys use corresponding foreign-key columns.

## Existing models and generator reruns

> Compatible existing storage is reused. If its required indexes, non-null columns or concrete foreign key are missing, the generator adds a repair migration. It does not rewrite existing rows: reconcile null values or orphaned rows before running that migration. A conflicting owner relationship is rejected before new artifacts are written.

Existing files are preserved. A repeated compatible command does not add duplicate associations or migrations. An incompatible archive owner/model or pending migration causes an error rather than silently wiring another model to the wrong table.

Changing concrete ownership or converting to polymorphic storage requires an explicit model/schema change; rerunning with `--polymorphic` is not a conversion. Review existing associations and key types before making that change.
