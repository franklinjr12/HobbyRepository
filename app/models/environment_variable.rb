class EnvironmentVariable < ApplicationRecord
  KEY_FORMAT = /\A[A-Z_][A-Z0-9_]*\z/
  MASK = "********".freeze

  belongs_to :app

  before_validation :normalize_key

  validates :key, presence: true,
                  uniqueness: { scope: :app_id },
                  format: {
                    with: KEY_FORMAT,
                    message: "must start with a letter or underscore and use only uppercase letters, numbers, and underscores"
                  }
  validates :value, presence: true

  scope :ordered, -> { order(:key) }

  def display_value
    secret? ? MASK : value
  end

  def runtime_pair
    [ key, value ]
  end

  def metadata
    {
      key: key,
      secret: secret?
    }
  end

  private

  def normalize_key
    self.key = key.to_s.strip.upcase if key.present?
  end
end
