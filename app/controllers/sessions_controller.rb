class SessionsController < ApplicationController
  skip_before_action :require_authentication, only: %i[new create]

  def new
  end

  def create
    user = User.find_by(email: params.expect(:email).to_s.strip.downcase)

    if user&.authenticate(params.expect(:password))
      session[:user_id] = user.id
      redirect_to dashboard_path, notice: "Signed in."
    else
      flash.now[:alert] = "Email or password is incorrect."
      render :new, status: :unprocessable_content
    end
  end

  def destroy
    reset_session
    redirect_to sign_in_path, notice: "Signed out."
  end
end
