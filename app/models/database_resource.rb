require "securerandom"

class DatabaseResource < ApplicationRecord
  MASK = "********".freeze
  DEFAULT_DATABASE_TYPE = "postgres".freeze
  DEFAULT_HOST = "localhost".freeze
  DEFAULT_PORT = 5432
  STATUSES = %w[pending provisioning available failed disabled].freeze
  DATABASE_TYPES = %w[postgres].freeze

  belongs_to :app
  has_many :database_backups, dependent: :destroy

  before_validation :assign_defaults

  validates :app_id, uniqueness: true
  validates :database_type, inclusion: { in: DATABASE_TYPES }
  validates :database_name, :username, :encrypted_password, :status, presence: true
  validates :database_name, :username, uniqueness: true,
                                      format: {
                                        with: /\A[a-z][a-z0-9_]*\z/,
                                        message: "must start with a lowercase letter and use lowercase letters, numbers, and underscores"
                                      }
  validates :status, inclusion: { in: STATUSES }
  validates :port, numericality: { only_integer: true, greater_than: 0, less_than: 65_536 }
  validates :database_url_env_var, :database_name_env_var, :username_env_var, :password_env_var,
            :host_env_var, :port_env_var,
            presence: true,
            format: {
              with: EnvironmentVariable::KEY_FORMAT,
              message: "must start with a letter or underscore and use only uppercase letters, numbers, and underscores"
            }

  scope :available, -> { where(status: "available") }

  def available?
    status == "available"
  end

  def password
    self.class.decrypt(encrypted_password)
  end

  def password=(raw_password)
    self.encrypted_password = self.class.encrypt(raw_password)
  end

  def rotate_credentials!
    self.password = self.class.generated_password
    self.credentials_rotated_at = Time.current
    self.status = "available" if status == "failed"
    save!

    app.record_event!(
      "database.credentials_rotated",
      "Database credentials were rotated for #{app.name}",
      metadata: public_metadata
    )
  end

  def mark_provisioned!
    update!(status: "available", provisioned_at: Time.current, failure_message: nil)
    app.record_event!(
      "database.provisioned",
      "Database access was provisioned for #{app.name}",
      metadata: public_metadata
    )
  end

  def mark_failed!(message)
    update!(status: "failed", failure_message: message)
    app.record_event!(
      "database.provision_failed",
      "Database provisioning failed for #{app.name}",
      metadata: public_metadata.merge(error: message)
    )
  end

  def connection_url
    URI::Generic.build(
      scheme: "postgres",
      userinfo: "#{username}:#{password}",
      host: host,
      port: port,
      path: "/#{database_name}"
    ).to_s
  end

  def runtime_environment
    return {} unless available?

    {
      database_url_env_var => connection_url,
      database_name_env_var => database_name,
      username_env_var => username,
      password_env_var => password,
      host_env_var => host,
      port_env_var => port.to_s
    }
  end

  def display_runtime_environment
    runtime_environment.transform_values { MASK }
  end

  def public_metadata
    {
      database_resource_id: id,
      database_type: database_type,
      database_name: database_name,
      username: username,
      status: status,
      env_vars: env_var_names
    }
  end

  def env_var_names
    [
      database_url_env_var,
      database_name_env_var,
      username_env_var,
      password_env_var,
      host_env_var,
      port_env_var
    ]
  end

  def self.generated_password
    SecureRandom.urlsafe_base64(32)
  end

  def self.encrypt(value)
    encryptor.encrypt_and_sign(value)
  end

  def self.decrypt(value)
    encryptor.decrypt_and_verify(value)
  end

  def self.encryptor
    secret = Rails.application.secret_key_base
    salt = "database-resource-password"
    key = ActiveSupport::KeyGenerator.new(secret).generate_key(salt, ActiveSupport::MessageEncryptor.key_len)
    ActiveSupport::MessageEncryptor.new(key)
  end

  private

  def assign_defaults
    self.database_type = DEFAULT_DATABASE_TYPE if database_type.blank?
    self.status = "pending" if status.blank?
    self.host = ENV.fetch("HOBBY_DATABASE_HOST", DEFAULT_HOST) if host.blank?
    self.port = ENV.fetch("HOBBY_DATABASE_PORT", DEFAULT_PORT).to_i if port.blank?
    assign_default_names if app
    self.password = self.class.generated_password if encrypted_password.blank?
  end

  def assign_default_names
    suffix = app.persisted? ? app.id : "new"
    base = "#{app.slug.presence || app.name || "app"}_#{suffix}".parameterize(separator: "_").tr("-", "_")
    self.database_name = "app_#{base}" if database_name.blank?
    self.username = "app_#{base}_user" if username.blank?
  end
end
