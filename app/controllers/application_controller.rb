class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :require_authentication
  helper_method :current_user

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  private

  def current_user
    Current.user ||= User.find_by(id: session[:user_id]) if session[:user_id]
  end

  def require_authentication
    return if current_user

    redirect_to sign_in_path, alert: "Please sign in."
  end

  def render_not_found
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end

  def require_admin
    return if current_user&.admin?

    render_not_found
  end
end
