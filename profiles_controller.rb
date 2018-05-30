class ProfilesController < ApplicationController
  before_action :user_profile
  before_action :profile_status
  before_action :school_driver_info, only: [:school_verification]
  layout :set_layout, only: [:school_verification, :setting]
  before_action :update_params, only: [:setting]
  before_action :authenticate_user!, only: [:setting]

  require 'securerandom'

  include ProfileService

  def notification
  end
  
  def resend_otp
    send_otp
  end

  def school_verification
    update_school_info if params[:school_pto_driver].present?
  end

  def setting
    @error = nil
    @url = setting_path 
    @remote = !@profile_active
    params[:commit] == "back" ? last_step : next_step
  end

  def verify_otp
    render json: { msg: 'OTP field is empty', type: 'error' } and return if params[:otp].blank?
    type = VerificationCode.where(mobile_number: @profile.contact).first.try(:code) == params[:otp] ? 'success' : 'error'
    @profile.update(contact_verification: true) if type=='success'
    msg = case type
            when 'success' then 'Contact number verified'
            when 'error' then 'Verification failed!, invalid OTP'
          end
    render json: {msg: msg, type: type}
  end

  private

    def activate_profile
      [current_user.update(steps: 2), @error='Your mobile number is not verified.'] and return unless @profile.contact_verification?
      @profile.update(profile_active: true)
      update_customer
      unless @error
        flash[:notice] = "Profile completed and active to use services."
        redirect_to root_path
      end
    end

    def profile_status
      @profile_active = @profile.profile_active
    end

    def params_profile
      params[:profile].try(:permit!)
    end

    def params_user
      params[:user].try(:permit!)
    end

    def set_step_n_notice
      if (@profile.age < 14 rescue false)
        @step = 1
        @error = "To use the services your age must be above 13 years."
      elsif @error.present?
        @step = params[:step] || '1'
      end
    end

    def school_verification_params
      params[:school_pto_driver].permit!
    end

    def school_driver_info
      @school_driver_info = current_user.try(:school_pto_driver)
    end

    def set_layout
      'profile'
    end
    
    def twilo_client
      twilio_sid = Rails.application.secrets[:twilio_sid]
      twilio_token = Rails.application.secrets[:twilio_token]
      return Twilio::REST::Client.new twilio_sid, twilio_token
    end

    def update_customer
      state = current_user.profile.state
      country = current_user.profile.country
      zipcode_customer = current_user.profile.zipcode.values.first
      random = SecureRandom.hex(2)
      customer_id=("#{country}-#{state}-#{zipcode_customer}-#{random}")
      @profile.update(customer_id: customer_id)
    end

    def update_params
      params[:profile][:ssn_number] = params[:profile][:ssn_number].gsub('-','') if params[:profile][:ssn_number].present? rescue nil
      params[:profile][:zipcode] = params[:profile][:zipcode].to_json if params[:profile][:zipcode].present? rescue nil
    end
    
    def user_profile
      redirect_to new_user_session_path and return unless user_signed_in?
      @profile = current_user.try(:profile)
    end
   
end
