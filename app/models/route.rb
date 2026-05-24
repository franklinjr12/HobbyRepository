class Route < ApplicationRecord
  ROUTE_TYPES = %w[generated_subdomain custom_domain].freeze
  TLS_STATUSES = %w[not_configured pending active failed].freeze
  OWNERSHIP_STATUSES = %w[pending verified failed].freeze
  DEFAULT_BASE_DOMAIN = "localhost".freeze

  belongs_to :app

  before_validation :normalize_hostname
  before_validation :assign_custom_domain_defaults

  validates :hostname, presence: true,
                       uniqueness: true,
                       format: {
                         with: /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/,
                         message: "must be a valid hostname"
                       }
  validates :route_type, inclusion: { in: ROUTE_TYPES }
  validates :tls_status, inclusion: { in: TLS_STATUSES }
  validates :ownership_status, inclusion: { in: OWNERSHIP_STATUSES }
  validates :ownership_token, uniqueness: true, allow_blank: true
  validate :custom_domain_must_not_use_platform_domain

  scope :active, -> { where(active: true) }
  scope :generated_subdomain, -> { where(route_type: "generated_subdomain") }
  scope :custom_domains, -> { where(route_type: "custom_domain") }

  def self.generated_hostname_for(app)
    "#{app.slug}.#{ENV.fetch('PLATFORM_DEFAULT_ROUTE_DOMAIN', DEFAULT_BASE_DOMAIN)}"
  end

  def self.resolve_hostname(hostname)
    active.find_by(hostname: hostname.to_s.downcase)
  end

  def verify_ownership!(token)
    if custom_domain? && ActiveSupport::SecurityUtils.secure_compare(ownership_token.to_s, token.to_s)
      update!(ownership_status: "verified", ownership_verified_at: Time.current)
      app.record_event!(
        "domain.verified",
        "#{hostname} ownership was verified",
        metadata: public_status
      )
      true
    else
      update!(ownership_status: "failed") if custom_domain?
      false
    end
  end

  def provision_tls!
    raise ArgumentError, "Domain ownership must be verified before TLS can be provisioned." unless verified?

    update!(tls_status: "active", tls_provisioned_at: Time.current, active: true)
    app.record_event!(
      "domain.tls_active",
      "TLS was provisioned for #{hostname}",
      metadata: public_status
    )
  end

  def verified?
    ownership_status == "verified"
  end

  def custom_domain?
    route_type == "custom_domain"
  end

  def dns_instruction
    return nil unless custom_domain?

    "Create a TXT record for _platform-verify.#{hostname} with value #{ownership_token}."
  end

  def public_status
    {
      hostname: hostname,
      route_type: route_type,
      ownership_status: ownership_status,
      tls_status: tls_status,
      active: active
    }
  end

  private

  def normalize_hostname
    self.hostname = hostname.to_s.strip.downcase
  end

  def assign_custom_domain_defaults
    if route_type != "custom_domain"
      self.ownership_status = "verified" if ownership_status.blank? || ownership_status == "pending"
      return
    end

    self.active = false if active.nil?
    self.tls_status = "not_configured" if tls_status.blank?
    self.ownership_status = "pending" if ownership_status.blank?
    self.ownership_token = SecureRandom.hex(16) if ownership_token.blank?
  end

  def custom_domain_must_not_use_platform_domain
    return unless route_type == "custom_domain"

    platform_domain = ENV.fetch("PLATFORM_DEFAULT_ROUTE_DOMAIN", DEFAULT_BASE_DOMAIN)
    errors.add(:hostname, "must not use the platform route domain") if hostname == platform_domain || hostname.end_with?(".#{platform_domain}")
  end
end
