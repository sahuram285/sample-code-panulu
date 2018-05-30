module ProfileService
  
  def check_profile_verification
    current_user.profile.update(profile_active: false) unless !current_user.try(:ssn_detail).try(:verified)
  end
  
  # Check mandatory field for registration process and keep user where they left last time
  # So that it will prevent user to update, if someone try to update DB without completing required details.
  def check_mandatory_fields prms
    if prms.present?
      case @step.to_i
        when 0
          zipcode = JSON.parse(prms[:zipcode])["1"] 
          blank_fields = %w(zipcode first_name last_name).select{ |field| field if prms[field].blank?}
        when 1
          blank_fields = %w(address_1 address_2 city state country contact dob).map { |field| field if prms[field].blank?}
        when 2
          blank_fields = if params[:role].blank?
              'Select atleast one role'
            elsif params[:role][:service_provider].present?
              'Select atleast one service' if %w(pick_and_drop local_errands food_services).collect{ |service| params[:profile][service].to_i}.sum.eql?(0)
            else 
              %w(pick_and_drop local_errands food_services).map{|service| params[:profile][service] = false}
            end
        when 4
          if @profile.age > 17 && @profile.present?
            blank_fields = %w(user_image user_license_copy).select { |field| field if (prms[field].blank? && @profile[field].blank?)}
            blank_fields << %w(user_license_number).select { |field| field if prms[field].blank? }
          else
            blank_fields = %w(user_image parent_image parent_license_copy).select {|field| field if (prms[field].blank? && @profile[field].blank?) }
            blank_fields << %w(parent_name parent_license_number).select {|field| field if prms[field].blank? }
          end
        when 5
          blank_fields = %w(ssn_number).select {|field| field if prms[field].blank? }
        when 6
          blank_fields = %w(vehicle_model vehicle_color vehicle_no vehicle_registration_no vehicle_registration_image).select {|field| field if prms[field].blank? }
      end

      blank_fields = blank_fields.try(:flatten).try(:compact) if blank_fields.is_a?(Array)

      @error =  if blank_fields.is_a?(String)
                  blank_fields
                elsif blank_fields.any?
                  "* Mandatory fields: " + blank_fields.map{ |f| f.titleize }.join(', ')
                end unless blank_fields.nil?
    end
  end

  def field_value params, field, f, i = nil
    flash.clear
    if field == :zipcode
      if params[:profile].present? && params[:profile][field].present?
        JSON.parse(params[:profile][field])[i] 
      else
        f.object.zipcode.present? ? f.object.zipcode[i] : ''
      end 
    elsif field == :dob
       if params[:profile].present? && params[:profile][field].present?
          params[:profile][field]
       elsif f.object.dob.present?
          f.object.dob.strftime('%d/%m/%Y') 
       end
    else
      if params[:profile].present? && !params[:profile][field].nil?
        params[:profile][field]
      elsif field.to_s.include?('_image')
        @profile[field].url rescue nil
      else
        f.object[field]
      end
    end
  end

  def last_step
    @step = ((params[:step] || current_user.steps).to_i - 1).to_s
  end

  def next_step
    @step = params[:step] || current_user.steps
    check_mandatory_fields params_profile
    if @error.blank?
      update_profile params_profile
      update_user params_user if @error.blank?
      @step = current_user.steps unless @profile_active
    end
  end

  def otp_msg
    otp = SecureRandom.hex(3)
    VerificationCode.where(mobile_number: @profile.contact).first_or_initialize.update(code: otp)
    msg = "Use #{otp} as one time password (OTP) to verify your contact for panulu account."
  end

  def profile_form_title step
    case step.to_i
    when 0 then 'Login detail'
    when 1 then 'Basic Info'
    when 2 then 'Service type'
    when 3 then 'Service area'
    when 4 then 'Provider Info'
    when 5 then 'SSN Check'
    when 6 then 'Your vehicle detail'
    end
  end

  def send_otp
    country_code = IsoCountryCodes.find(@profile.country).calling
    begin
      twilo_client.account.sms.messages.create(
        :from => Rails.application.secrets[:twilio_phone_number],
        :to => "#{country_code}#{@profile.contact.to_s.gsub(/[^0-9]/, "").to_i}",
        :body => "#{otp_msg}"
      )
    rescue Exception => e
      @error = e
    end
  end

  def ssn_record_exist
    @profile.ssn_number == current_user.try(:ssn_detail).try(:ssn)
  end

  def update_profile prms
    unless prms.blank?
      ssn = prms[:ssn_number] if prms[:ssn_number].present?
      update_ssn_prms(prms) if prms[:ssn_number].present?
      contact = @profile.contact
      @profile.update prms
      case @step.to_i
        when 0
          update_coordinates
        when 1
          update_contact_status contact, prms[:contact]
          update_age
        when 2
          update_service
        when 3
          update_coordinates
          activate_profile unless current_user.has_role? :service_provider
        when 5
          verify_ssn(ssn)
          activate_profile unless @error
      end
      set_step_n_notice
      @success = "Profile updated succesfully" if (@error.blank? && @profile_active)
    end
  end

  def update_user prms
    current_user.update prms unless prms.blank?
  end

  def update_coordinates
    coordinate = {}
    begin
      @profile.zipcode.map do |index,zip_code|
        if zip_code.present? && (JSON.parse(@profile.coordinates)[zip_code].blank? rescue true)
          lat = Geocoder.coordinates(zip_code)[0] rescue ''
          long = Geocoder.coordinates(zip_code)[1] rescue ''
          coordinate[zip_code] = ({"lat" => lat,"long" => long})
        else
          coordinate[zip_code] = JSON.parse(@profile.coordinates)[zip_code]
        end
      end
    rescue
      nil
    end
    @profile.coordinates = coordinate.to_json
    @profile.save
  end

  def update_service
    if params[:role].blank?
      @error = "Please select at least 1 role"
    else
      current_user.update(role_ids:[])
      params[:role].values.map{ |role| current_user.add_role role }
    end
    current_user.profile.update(pick_and_drop: false, local_errands: false, food_services: false) if !params[:role].values.include?('service_provider')
    check_profile_verification if (@profile_active && (current_user.has_role? :service_provider))
  end

  def update_contact_status old_contact, new_contact
    if old_contact != new_contact
      @profile.update(contact_verification: false)
      send_otp
    elsif !@profile.contact_verification
      send_otp
    end
  end

  def update_age
    dob = DateTime.strptime(params[:profile][:dob], "%m/%d/%Y") rescue DateTime.parse(params[:profile][:dob], "%m/%d/%Y")
    age_in_years = ((DateTime.now.year*12 + DateTime.now.month)-(dob.year*12 + dob.month))/12
    @profile.update(age: age_in_years, dob: dob)
  end

  def update_user_ssn_detail ssn, candidate, report, trace, criminal_record, terrorist_watchlist_record
    current_user.build_ssn_detail.save if current_user.ssn_detail.blank?
    current_user.ssn_detail.update(candidate: candidate.to_json, report: report.to_json, trace: trace.to_json, criminal_record: criminal_record.to_json, terrorist_watchlist_record: terrorist_watchlist_record.to_json, ssn: ssn)
  end

  def update_guardian_dob
    unless params[:profile][:parents_dob].nil?
      dob = DateTime.strptime(params[:profile][:parents_dob], "%m/%d/%Y") rescue DateTime.parse(params[:profile][:parents_dob], "%m/%d/%Y")
      @profile.update( parents_dob: dob)
    end
  end

  def update_school_info
    current_user.school_pto_driver.update(school_verification_params)
    ApplicationMailer.school_verification(school_verification_params, current_user).deliver
  end

  def update_ssn_prms prms
    prms[:ssn_number] = "#{@profile.zipcode['1']}-#{prms[:ssn_number].last(4)}"    
  end

  def verify_ssn ssn
    unless ssn_record_exist
      begin
        update_guardian_dob if @profile.age.between?(14,17)
        candidate = Checkr::Candidate.create({
          first_name: @profile.first_name,
          last_name: @profile.last_name,
          no_middle_name: true,
          dob: ( @profile.age.between?(14,17) ? @profile.parents_dob : @profile.dob),
          ssn: ssn,
          phone: @profile.contact,
          email: current_user.email,
          zipcode: @profile.zipcode['1']
        })
        report = Checkr::Report.create( package: 'tasker_standard', candidate_id: candidate.id)
        trace = Checkr::SsnTrace.find(report.ssn_trace_id)
        criminal_search = Checkr::NationalCriminalSearch.find( report.national_criminal_search_id )
        terrorist_watchlist_search= Checkr::TerroristWatchlistSearch.find( report.terrorist_watchlist_search_id )
        update_user_ssn_detail @profile.ssn_number, candidate.as_json["table"], report.as_json["table"], trace.as_json["table"], criminal_search.as_json["table"], terrorist_watchlist_search.as_json["table"]
      rescue Exception => e
        @error = JSON.parse(e.message)["error"]
      end
    end
  end
end