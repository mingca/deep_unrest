class ApplicationController < JSONAPI::ResourceController
  include DeviseTokenAuth::Concerns::SetUserByToken
  protect_from_forgery with: :null_session

  def context
    { current_user: current_applicant || current_admin }
  end

  def update
    redirect = allowed_params[:redirect]
    DeepUnrest.perform_update(allowed_params[:data],
                              current_applicant || current_admin)
    if redirect
      redirect_to redirect
    else
      render json: {}, status: 200
    end
  rescue DeepUnrest::Conflict => err
    render json: err.message, status: 409
  end

  def allowed_params
    params.permit(:redirect,
                  data: [:destroy,
                         :path,
                         { attributes: {} }])
  end
end
