class Profile < ActiveRecord::Base
  belongs_to :user
  # validates_uniqueness_of :ssn_number
	mount_uploader :user_image, AvatarUploader
	mount_uploader :user_license_copy, AvatarUploader
	mount_uploader :parent_image, AvatarUploader
	mount_uploader :parent_license_copy, AvatarUploader
  mount_uploader :vehicle_registration_image, AvatarUploader
 
  ETHINICITY = ['Chinese','Mexican','Italian','sushi','Greek','French','Thai','Spanish','Indian','Mediterranean']
 
   def common_search params
    @list_or_sp = if FoodService.where('description LIKE ? OR ethinicity LIKE ? OR location LIKE ?', "#{params[:query]}", "#{params[:query]}", "#{params[:query]}").present?
      get_local_area_sp(:FoodServices, params[:lat], params[:long])
    elsif LocalErrand.where('category LIKE ? OR subcategory LIKE ? OR description LIKE ?', "#{params[:query]}", "#{params[:query]}", "#{params[:query]}").present?
      get_local_area_sp(:LocalErrands, params[:lat], params[:long])
    elsif PickAndDrop.where('category LIKE ? OR subcategory LIKE ? OR description LIKE ?', "#{params[:query]}", "#{params[:query]}", "#{params[:query]}").present?
      get_local_area_sp(:PickAndDrop, params[:lat], params[:long])
    else
      Profile.where('category LIKE ? OR subcategory LIKE ?', "#{params[:query]}", "#{params[:query]}") || 'no result found...'
    end 
    render json: {service_provider: @list_or_sp}
  end

  def fullname
    "#{self.first_name} #{self.last_name}"
  end

  # Collect all service providers who work on that zipcode
  def get_local_area_sp service, lat, long
    zipcode = Geocoder.search("#{lat},#{long}").first.postal_code rescue nil
    Profile.where("profiles.zipcode like ? AND profiles.#{service.to_s.underscore} = ?","%#{zipcode}%", true)
  end

  def self.search filter,user
    user_ids = User.with_role(:service_provider).collect(&:id)
    zipcode = Geocoder.search("#{filter[:latitude]}, #{filter[:longitude]}").first.postal_code rescue nil
    profiles = Profile.where(:user_id=>user_ids).where("zipcode LIKE ?","%#{filter[:zipcode]}%")
    if profiles.present?
      #pick_and_drop
      profiles = profiles.where(:pick_and_drop => filter[:services][:pick_and_drop]) if filter[:pick_and_drop]eql?('1')
      #local_errands
      profiles = profiles.where(:local_errands => filter[:services][:local_errands]) if filter[:local_errands]eql?('1')
      #food_services
      profiles = profiles.where(:food_services => filter[:services][:food_services]) if filter[:food_services]eql?('1')
      #zipcode  
      profiles = profiles.where("zipcode LIKE ?","%#{filter[:zipcode]}%") if filter[:zipcode].present?
      #rating
      profiles = profiles.where("food_services_rating = '#{filter[:rating]}' OR pick_and_drop_rating = '#{filter[:rating]}' OR local_errands_rating = '#{filter[:rating]}'")  if filter[:rating].present?
      #ethinicity
      profiles = profiles.where("ethinicity like ?", filter[:ethinicity]) if filter[:ethinicity].present?
      #sort_by_distance
      profiles = profiles.where('profiles.zipcode like ?', "%#{zipcode}%") if filter[:sort_by_distance] == 1
      #service_average_rating
      profiles = profiles.where("food_services_rating = 4 OR food_services_rating = 5 OR pick_and_drop_rating = 4 OR pick_and_drop_rating =5 OR local_errands_rating = 4 OR local_errands_rating = 5") if filter[:most_popular] == 1

      return profiles
    end
  end

  def zipcode
    begin
      JSON.parse(super)
    rescue Exception => e
      # eval(super)
    end
  end

end