# Service for handling the automatic rescheduling/canceling of unfilled bookings.
module RescheduleOrCancelUnfilledService
  MAX_OFFSET = 8 * 7 # up to 8 weeks away

  class << self
    def auto_rbu_or_cbu_candidate?(booking, date_start: booking.date_start)
      return false unless booking.confirmed
      return false if booking.provider.present?

      window = auto_rbu_or_cbu_minutes(region: booking.region, service: booking.service).minutes

      ((date_start - window)...date_start).cover?(Time.current)
    end

    # Get bookings in need of auto-RBU/CBU
    # @return array of eligible bookings
    def bookings_to_reschedule_or_cancel
      regions  = Region.select { |region| ConfigParam.regional_auto_rbu?(region) }
      start_at = Time.current
      window = [RegionAutoAcceptWindow.maximum(:auto_rbu_minutes).to_i, RegionAutoAcceptWindow::AUTO_RBU_WINDOW_MINUTES].max
      end_at   = start_at + window.minutes

      Booking.unfilled_by_regions_and_time(regions, start_at, end_at).
        select{ |booking| booking.auto_rbu_or_cbu? } # This is not great, but is fast enough.
    end

    # Automatically RBU (Reschedule By Us) or CBU (Cancel By Us) an unfilled booking. Attempts to
    # reschedule the booking to a suitable date. If that's not possible, cancels the booking.
    #
    # @param booking [Booking] unfilled booking to be RBU/CBU'd
    def reschedule_or_cancel(booking)
      return if MultipleProviderBookingService.try_double_assign_pro_to_prevent_dual_pro_rbu(booking)
      return if !ConfigParam.regional_auto_rbu?(booking.region)

      if !booking.auto_rbu_or_cbu?
        data = {
          booking_confirmed: booking.confirmed?,
          provider_present: booking.provider.present?,
          date_start: booking.date_start,
          current_time: Time.current,
        }
        Loggers::AutoRBUAndCBU.error(
          booking_id:          booking.id,
          original_date_start: booking.date_start.to_s,
          new_date_start:      nil,
          reason_id:           reason.try!(:id),
          type:                'rbu',
          message:             '(FAILED) '+ "Failed auto_rbu_or_cbu check. Data = #{ data.to_s }."
        )

        return
      end

      if booking.auto_rbu_count < booking.auto_rbu_attempts
        reschedule(booking)
      else
        raise(ServiceErrors::RbuLimitError)
      end
    rescue ServiceErrors::RbuLimitError, ServiceErrors::RbuError => e
      cancel(booking, e.cbu_reason, e.message)
    end

    # @return the next reschedulable date that meet the following criteria:
    #   1) In weekdays (Monday thru Thursday)
    #   2) The same start time as the booking
    #   3) A non-thresholded time slot for the entire booking duration
    def next_reschedulable_date(booking)
      (1...MAX_OFFSET).find do |offset|
        target_date = booking.date_start + offset.days

        next if bad_weekday?(target_date)
        next if holiday?(target_date, booking.region.country)

        return target_date
      end
    end

    def auto_rbu_or_cbu_minutes(region:, service:)
      minutes = RegionAutoAcceptWindow.where(region_id: region, service_id: service).first.try!(:auto_rbu_minutes)

      minutes || RegionAutoAcceptWindow::AUTO_RBU_WINDOW_MINUTES
    end

    private

    # RBU ("Rescheduled By Us") / CBU ("Canceled By Us")

    def reschedule(booking)
      original_date_start = booking.date_start
      recommended_providers = []

      smart_schedule_recommendations = booking.smart_schedule_recommendations(
        arrival_type: SmartScheduling::SmartScheduler::ArrivalType::WAYFAIR_RBU
      )

      if smart_schedule_recommendations.present?
        recommended_providers = smart_schedule_recommendations.providers
        new_date_start = smart_schedule_recommendations.start_time
      else
        reschedule_days = ConfigParam.reschedule_days(booking.region)
        return next_reschedulable_date(booking) if reschedule_days.exclude?(Date::DAYNAMES[booking.date_start.wday].downcase.to_sym)

        # get first day of week to reschedule to, eg :monday or :tuesday
        best_day_to_reschedule = reschedule_days[Date::DAYNAMES[booking.date_start.wday].downcase.to_sym]

        # min_offset to the first best_day_to_reschedule (which may be before the booking date_start)
        min_offset = (date_of_next(best_day_to_reschedule) - booking.date_start.to_date).to_i

        # get all required days_of week upto MAX_OFFSET/7 weeks from booking start date
        candidate_dates = (min_offset...MAX_OFFSET).step(7).map { |offset| booking.date_start + offset.days }

        new_date_start = candidate_dates.find do |candidate_date|
          candidate_date > booking.date_start &&
            !holiday?(candidate_date, booking.region.country)
        end
      end

      if new_date_start.blank?
        raise(ServiceErrors::RbuError, 'No time slot is available in the coming 8 weeks')
      end

      rescheduler = Rescheduler.new(booking, reason_id: rbu_reason.id, from_admin: true)
      rescheduler.reschedule_to(new_date_start, recommended_providers: recommended_providers)

      if rescheduler.errors.include?(Rescheduler::PICK_ANOTHER_BOOKING)
        raise(ServiceErrors::RbuError, 'Cannot reschedule the booking later than an existing recurring booking')
      end

      Loggers::AutoRBUAndCBU.info(
        booking_id:          booking.id,
        original_date_start: original_date_start.to_s,
        new_date_start:      booking.date_start.to_s,
        reason_id:           rbu_reason.id,
        type:                'rbu',
        message:             'Success'
      )
    end

    def cancel(booking, reason, message)
      cancellation = BookingCancellation.new(
        booking_id: booking.id,
        why:        reason.id
      )

      cancellation.calculate_refund!
      success = cancellation.trigger!(cancellation_type: :reschedule_or_cancel_unfilled_service)

      if success
        Loggers::AutoRBUAndCBU.info(
          booking_id:          booking.id,
          original_date_start: booking.date_start.to_s,
          new_date_start:      nil,
          reason_id:           reason.id,
          type:                'cbu',
          message:             message
        )
        booking.user.send_message(:auto_canceled, booking)
      else
        Loggers::AutoRBUAndCBU.error(
          booking_id:          booking.id,
          original_date_start: booking.date_start.to_s,
          new_date_start:      nil,
          reason_id:           reason.try!(:id),
          type:                'cbu',
          message:             '(FAILED) '+ message + ", Errors: #{cancellation.errors.join(',')}"
        )
      end
    end

    def bad_weekday?(target_date)
      good_wdays = (1..4) # Monday, Tuesday, Wednesday, Thursday
      !good_wdays.include?(target_date.wday)
    end

    def holiday?(date, country)
      return true if Holidays.on(date, country.downcase.to_sym, :observed).any?

      # Black Friday
      holidays_on(date - 1.day, country).each do |holiday|
        return true if "Thanksgiving".downcase.include?(holiday.downcase)
      end

      # Christmas Eve
      holidays_on(date - 1.day, country).each do |holiday|
        return true if "Christmas Day".downcase.include?(holiday.downcase)
      end

      # New Year's Eve
      holidays_on(date - 1.day, country).each do |holiday|
        return true if "New Year's Day".downcase.include?(holiday.downcase)
      end

      false
    end

    def near_holiday?(pattern, holidays)
      holidays.any? do |holiday|
        pattern.downcase.include?(holiday.downcase)
      end
    end

    def holidays_on(date, country)
      Holidays.on(date, country.downcase.to_sym, :observed).map { |holiday| holiday[:name] }
    end

    def rbu_reason
      Reason::Reschedule.automated_reschedule_by_us
    end

    def date_of_next(day_name)
      date = Date.parse(day_name.to_s)
      delta = date > Date.today ? 0 : 7
      date + delta
    end
  end
end
