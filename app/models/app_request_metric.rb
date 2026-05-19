class AppRequestMetric < ApplicationRecord
  belongs_to :app

  before_validation :assign_default_occurrence

  validates :occurred_at, presence: true
  validates :status_code,
            numericality: { only_integer: true, greater_than_or_equal_to: 100, less_than: 600 },
            allow_nil: true
  validates :wake_duration_ms,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true

  scope :recent, ->(limit = 20) { order(occurred_at: :desc).limit(limit) }
  scope :cold_starts, -> { where(cold_start: true) }

  private

  def assign_default_occurrence
    self.occurred_at ||= Time.current
  end
end
