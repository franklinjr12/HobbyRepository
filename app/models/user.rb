class User < ApplicationRecord
  has_secure_password

  has_many :apps, foreign_key: :owner_id, inverse_of: :owner, dependent: :restrict_with_error
  has_many :team_memberships, dependent: :destroy
  has_many :teams, through: :team_memberships

  def accessible_apps
    App.where(owner: self).or(App.where(team: teams))
  end

  def can_manage_app?(app)
    return true if admin? || app.owner_id == id

    membership = app.team&.membership_for(self)
    membership&.can_manage_apps? || false
  end

  before_validation :normalize_email

  validates :email, presence: true,
                    uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, allow_nil: true

  private

  def normalize_email
    self.email = email.to_s.strip.downcase
  end
end
