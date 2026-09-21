gem 'activerecord', ENV.fetch('AUTH_AR_VERSION', '>= 8.0')
require 'logger'
require 'active_record'
require 'bcrypt'
require_relative '../../lib/rails_vouch'
ActiveRecord::Base.establish_connection(adapter: 'postgresql', database: ENV.fetch('PGDATABASE', 'vouch_test'))
c = ActiveRecord::Base.connection
c.execute('CREATE TEMP TABLE compat_hosts (id bigserial primary key)')
c.execute('CREATE TEMP TABLE compat_backups (id bigserial primary key, host_id bigint, code_digest varchar, used_at timestamp)')
class CompatHost < ActiveRecord::Base
 self.table_name = 'compat_hosts'
 include Vouch::BackupCodable
 has_many :backup_codes, class_name: 'CompatBackup', foreign_key: :host_id
end
class CompatBackup < ActiveRecord::Base
 self.table_name = 'compat_backups'
end
host = CompatHost.create!
row = host.backup_codes.create!(code_digest: BCrypt::Password.create('abc123'))
puts "Rails #{ActiveRecord::VERSION::STRING}"
raise 'first consumption failed' unless host.consume_backup_code!('abc123').ok?
raise 'consumption did not persist' unless row.reload.used_at
raise 'backup code replay accepted' if host.consume_backup_code!('abc123').ok?


require_relative '../../lib/vouch/lockout_counter'
require_relative '../../lib/vouch/recoverable'
ActiveRecord::Base.connection.execute('CREATE TEMP TABLE compat_recoverables (id bigserial primary key, recovery_attempts bigint DEFAULT 0 NOT NULL, recovery_locked_at timestamp)')
class CompatRecoverable < ActiveRecord::Base
 self.table_name = 'compat_recoverables'
 include Vouch::Recoverable
 def auth_config(namespace, attribute)
  {lockout_duration: 1800, max_attempts: 3}.fetch(attribute)
 end
end
host = CompatRecoverable.create!
3.times { raise 'blank recovery code accepted' if host.consume_recovery_code!('').ok? }
raise 'recovery attempts did not persist' unless host.reload.recovery_attempts == 3
raise 'recovery lock did not persist' unless host.recovery_locked_at
puts 'Backup replay and recovery lockout regressions passed'
ActiveRecord::Base.connection_pool.disconnect!
