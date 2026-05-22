Rails.application.routes.draw do
  app_hostname = lambda do |request|
    Route.resolve_hostname(request.host).present?
  end

  constraints app_hostname do
    root "local_gateway#proxy", as: :local_gateway_root
    match "*path", to: "local_gateway#proxy", via: :all
  end

  root "dashboard#index"
  get "dashboard", to: "dashboard#index", as: :dashboard
  get "sign_in", to: "sessions#new"
  post "sign_in", to: "sessions#create"
  delete "sign_out", to: "sessions#destroy"
  resource :onboarding, only: %i[show], controller: :onboarding do
    post :create_sample_app
  end
  resources :apps, only: %i[index new create show edit update] do
    resources :environment_variables, only: %i[create update destroy]
    resources :database_backups, only: %i[show]
    resources :app_logs, only: %i[index], path: "logs" do
      post :collect, on: :collection
    end

    member do
      post :wake
      post :sleep
      post :deploy
      post :rollback
      post :inspect_runtime
      post :provision_database
      post :rotate_database_credentials
      post :backup_database
    end
  end

  namespace :admin do
    resources :apps, only: %i[index] do
      post :stop, on: :member
    end
    resources :users, only: %i[index new create]
    resource :health, only: %i[show], controller: :health
  end

  namespace :internal do
    scope :gateway, controller: :gateway do
      get :resolve
      post :wake
      get :wake_status
      post :activity
    end
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
