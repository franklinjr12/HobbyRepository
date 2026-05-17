class Route < ApplicationRecord
  ROUTE_TYPES = %w[generated_subdomain custom_domain].freeze
  TLS_STATUSES = %w[not_configured pending active failed].freeze
  DEFAULT_BASE_DOMAIN = "localhost".freeze

  belongs_to :app

  before_validation :normalize_hostname

  validates :hostname, presence: true,
                       uniqueness: true,
                       format: {
                         with: /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/,
                         message: "must be a valid hostname"
                       }
  validates :route_type, inclusion: { in: ROUTE_TYPES }
  validates :tls_status, inclusion: { in: TLS_STATUSES }

  scope :active, -> { where(active: true) }
  scope :generated_subdomain, -> { where(route_type: "generated_subdomain") }

  def self.generated_hostname_for(app)
    "#{app.slug}.#{ENV.fetch('PLATFORM_DEFAULT_ROUTE_DOMAIN', DEFAULT_BASE_DOMAIN)}"
  end

  def self.resolve_hostname(hostname)
    active.find_by(hostname: hostname.to_s.downcase)
  end

  private

  def normalize_hostname
    self.hostname = hostname.to_s.strip.downcase
  end
end
