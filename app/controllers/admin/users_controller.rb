module Admin
  class UsersController < BaseController
    def index
      @users = User.order(:email)
    end

    def new
      @user = User.new
    end

    def create
      @user = User.new(user_params)

      if @user.save
        redirect_to admin_users_path, notice: "#{@user.email} was created."
      else
        render :new, status: :unprocessable_content
      end
    end

    private

    def user_params
      params.expect(user: %i[name email password password_confirmation admin])
    end
  end
end
