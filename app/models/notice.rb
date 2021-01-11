class Notice < ActiveRecord::Base
  include Statisticable

  ADDRESS_ZIP_PATTERN =/.+(\d{5}).+/

  extend TimeSplitter::Accessors
  split_accessor :date

  include Bitfields
  bitfield :flags, 1 => :vehicle_empty, 2 => :hazard_lights, 4 => :expired_tuv, 8 => :expired_eco
  def self.details
    bitfields[:flags].keys
  end

  include Incompletable

  acts_as_api

  api_accessible(:public_beta) do |template|
    %i(token status street city zip latitude longitude registration color brand charge date photos).each { |key| template.add(key) }
    Notice.bitfields[:flags].keys.each { |key| template.add(key) }
  end

  api_accessible(:dump) do |template|
    %i(status street city zip latitude longitude registration color brand charge date).each { |key| template.add(key) }
    template.add(:attachments, as: :photos)
  end

  before_validation :defaults

  geocoded_by :geocode_address, language: Proc.new { |model| I18n.locale }, no_annotations: true
  after_validation :geocode, if: :do_geocoding?

  enum status: {open: 0, disabled: 1, analyzing: 2, shared: 3}
  enum severity: {standard: 0, hinder: 1, endanger: 2}

  belongs_to :user
  belongs_to :district, optional: true, foreign_key: :zip, primary_key: :zip
  belongs_to :bulk_upload, optional: true
  has_many_attached :photos
  has_many :replies, -> { order('created_at DESC') }, dependent: :destroy
  has_many :data_sets, -> { order('created_at DESC') }, dependent: :destroy, as: :setable

  validates :photos, :registration, :charge, :street, :zip, :city, :date, :duration, :severity, presence: :true
  validates :zip, format: { with: /\d{5}/, message: 'PLZ ist nicht korrekt' }
  validates :token, uniqueness: true
  validate :validate_creation_date, on: :create
  validate :validate_date

  scope :since, -> (date) { where('notices.created_at > ?', date) }
  scope :for_public, -> () { where.not(status: :disabled) }
  scope :search, -> (term) { where('registration ILIKE :term', term: "%#{term}%") }
  scope :preselect, -> () { shared.limit(3) }

  def self.for_reminder
    open.joins(:user).where(date: [(21.days.ago.beginning_of_day)..(14.days.ago.end_of_day)]).merge(User.not_disable_reminders).merge(User.active)
  end

  def self.from_param(token)
    find_by!(token: token)
  end

  def self.from_email_address(email)
    token = email[/^([^-]+)@.+/, 1]
    find_by!(token: token)
  end

  def self.statistics
    {
      photos: ActiveStorage::Attachment.where(record_type: Notice.to_s).count,
      all: Notice.count,
      incomplete: Notice.incomplete.count,
      shared: Notice.shared.count,
      users: Notice.pluck(:user_id).uniq.size,
      all_users: User.active.count,
      districts: District.active.count,
    }
  end

  def self.yearly_statistics(year, limit, base_scope: Notice.shared)
    notices = base_scope.reorder(nil).where(date: (Time.new(year)..Time.new(year).end_of_year))
    {
      count: notices.count,
      active: notices.pluck(:user_id).uniq.size,
      grouped_states: notices.joins(:district).select('count(districts.state) as state_count, districts.state').group('districts.state').order('state_count DESC').limit(limit).to_a,
      grouped_cities: notices.select('count(city) as city_count, city').group(:city).order('city_count DESC').limit(limit).to_a,
      grouped_zips: notices.select('count(zip) as zip_count, zip').group(:zip).order('zip_count DESC').limit(limit).to_a,
      grouped_charges: notices.select('count(charge) as charge_count, charge').group(:charge).order('charge_count DESC').limit(limit).to_a,
      grouped_brands: notices.select('count(brand) as brand_count, brand').where("brand != ''").group(:brand).order('brand_count DESC').limit(limit).to_a,
      grouped_registrations: notices.select('count(registration) as registration_count, registration').group(:registration).order('registration_count DESC').limit(limit).to_a,
    }
  end

  def display_charge
    standard? ? charge : "#{charge}, #{Notice.human_attribute_name(severity)}"
  end

  def wegli_email
    "#{token}@anzeige.weg-li.de"
  end

  def duplicate!
    notice = dup
    notice.token = nil
    notice.status = :open
    notice.photos.attach(photos.map(&:blob))
    notice.save_incomplete!
    notice.reload
  end

  def analyze!
    self.status = :analyzing
    save_incomplete!
    AnalyzerJob.set(wait: 1.second).perform_later(self)
  end

  def apply_dates(dates)
    sorted_dates = dates.compact.sort
    self.date = sorted_dates.first
    if date?
      duration = (sorted_dates.last.to_i - date.to_i)
      self.duration = durations.find { |d| duration >= d.minutes } || 1
    end
  end

  def durations
    Vehicle.durations.to_h.values.reverse
  end

  def apply_favorites(registrations)
    other = Notice.shared.since(1.month.ago).order(created_at: :desc).find_by(registration: registrations)
    if other
      self.registration = other.registration
      self.charge = other.charge if other.charge?
      self.severity = other.severity if other.severity?
      self.duration = other.duration if other.duration?
      self.brand = other.brand if other.brand?
      self.color = other.color if other.color?
      self.flags = other.flags if other.flags?
    end
  end

  def possible_registrations
    registrations = [registration]
    # TODO use results instead
    # registrations += data.flat_map {|_, result| Annotator.grep_text(result.deep_symbolize_keys) { |string| Vehicle.plate?(string) } }.map(&:first)
    registrations.flatten.compact.uniq
  end

  def date_doubles
    return false if registration.blank?

    user.notices.where('DATE(date) = DATE(?)', date).where(registration: registration).where.not(id: id)
  end

  def photo_doubles
    user.photos_attachments.joins(:blob).where('active_storage_attachments.record_id != ?', id).where('active_storage_blobs.filename' => photos.map { |photo| photo.filename.to_s })
  end

  def meta
    photos.map(&:metadata).to_json
  end

  def coordinates?
    latitude? && longitude?
  end

  def coordinates_missing?
    !coordinates?
  end

  def do_geocoding?
    coordinates_missing? && zip? && city? && street?
  end

  def distance_too_large?
    return if coordinates_missing?
    return if district.blank?

    Geo.distance(self, district) > Geo::MAX_DISTANCE
  end

  def point
    [latitude, longitude]
  end

  def handle_geocoding
    if coordinates?
      result = self.class.geocode([latitude, longitude])
      if result.present?
        self.zip = result[:zip]
        self.city = result[:city]
        self.street = result[:street]
      end
    end
  end

  def self.geocode(coords)
    results = Geocoder.search(coords)
    if results.present?
      best_result = results.first

      {
        zip: best_result.postal_code,
        city: best_result.city,
        street: "#{best_result.street} #{best_result.house_number}".strip,
      }
    end
  end

  def file_name(extension = :pdf)
    "#{date.strftime('%Y-%m-%d %H-%M')} #{registration.gsub(' ', '-')}.#{extension}"
  end

  def full_address
    "#{street}, #{zip} #{city}"
  end

  def full_location
    "#{location_and_address}, #{zip} #{city}"
  end

  def location_and_address
    [street, location].reject(&:blank?).join(", ")
  end

  def geocode_address
    # https://github.com/OpenCageData/opencagedata-misc-docs/blob/master/query-formatting.md
    "#{street.split(',').first}, #{zip}, #{city}, Deutschland"
  end

  def map_data(kind = :public)
    basic = {
      latitude: latitude,
      longitude: longitude,
      charge: charge,
      date: date,
      zip: zip,
    }

    case kind
    when :public
      basic
    when :private
      basic.merge(
        {
          registration: registration,
          full_address: full_address,
          token: token,
        }
      )
    else
      raise "kind #{kind} not surported"
    end
  end

  def to_param
    token
  end

  private

  def attachments
    photos.map do |photo|
      redirect_url = Rails.application.routes.url_helpers.rails_blob_url(photo, Rails.configuration.action_mailer.default_url_options)
      {
        filename: photo.filename,
        url: redirect_url,
      }
    end
  end

  def validate_date
    errors.add(:date, :invalid) if date.to_i > Time.zone.now.to_i
  end

  def validate_creation_date
    errors.add(:date, :invalid) if date.to_i < 3.month.ago.to_i
  end

  def defaults
    self.token ||= SecureRandom.hex(16)
  end
end
