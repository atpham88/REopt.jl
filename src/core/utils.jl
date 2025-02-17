# *********************************************************************************
# REopt, Copyright (c) 2019-2020, Alliance for Sustainable Energy, LLC.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without modification,
# are permitted provided that the following conditions are met:
#
# Redistributions of source code must retain the above copyright notice, this list
# of conditions and the following disclaimer.
#
# Redistributions in binary form must reproduce the above copyright notice, this
# list of conditions and the following disclaimer in the documentation and/or other
# materials provided with the distribution.
#
# Neither the name of the copyright holder nor the names of its contributors may be
# used to endorse or promote products derived from this software without specific
# prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
# OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
# OF THE POSSIBILITY OF SUCH DAMAGE.
# *********************************************************************************
function annuity(years::Int, rate_escalation::Real, rate_discount::Real)
    """
        this formulation assumes cost growth in first period
        i.e. it is a geometric sum of (1+rate_escalation)^n / (1+rate_discount)^n
        for n = 1, ..., years
    """
    return annuity_two_escalation_rates(years, rate_escalation, 0.0, rate_discount)
end


function annuity_two_escalation_rates(years::Int, rate_escalation1::Real, rate_escalation2::Real, rate_discount::Real)
    """
        this formulation assumes cost growth in first period
        i.e. it is a geometric sum of (1+rate_escalation1)^n * (1+rate_escalation2)^n / (1+rate_discount)^n
        for n = 1, ..., years
        which is refactored using (1+a)^n*(1+b)^n/(1+c)^n = ((1+a+b+a*b)/(1+c))^n
    """
    x = (1 + rate_escalation1 + rate_escalation2 + rate_escalation1 * rate_escalation2) / (1 + rate_discount)
    if x != 1
        pwf = round(x * (1 - x^years) / (1 - x), digits=5)
    else
        pwf = years
    end
    return pwf
end


function annuity_escalation(analysis_period::Int, rate_escalation::Real, rate_discount::Real)
    """
    :param analysis_period: years
    :param rate_escalation: escalation rate
    :param rate_discount: discount rate
    :return: present worth factor with escalation (inflation, or degradation if negative)
    NOTE: assumes escalation/degradation starts in year 2 (unlike the `annuity` function above)
    """
    pwf = 0
    for yr in range(1, stop=analysis_period + 1)
        pwf += (1 + rate_escalation)^(yr - 1) / (1 + rate_discount)^yr
    end
    return pwf
end


function levelization_factor(years::Int, rate_escalation::Real, rate_discount::Real, rate_degradation::Real)
    #=
    NOTE: levelization_factor for an electricity producing tech is the ratio of:
    - an annuity with an escalation rate equal to the electricity cost escalation rate, starting year 1,
        and a negative escalation rate (the tech's degradation rate), starting year 2
    - divided by an annuity with an escalation rate equal to the electricity cost escalation rate (pwf_e).
    Both use the offtaker's discount rate.
    levelization_factor is multiplied by each use of dvRatedProduction in reopt.jl 
        (except dvRatedProduction[t,ts] == dvSize[t] ∀ ts).
    This way the denominator is cancelled in reopt.jl when accounting for the value of energy produced
    since each value constraint uses pwf_e.

    :param analysis_period: years
    :param rate_escalation: escalation rate
    :param rate_discount: discount rate
    :param rate_degradation: positive degradation rate
    :return: present worth factor with escalation (inflation, or degradation if negative)
    NOTE: assume escalation/degradation starts in year 2
    =#
    num = 0
    for yr in range(1, stop=years)
        num += (1 + rate_escalation)^(yr) / (1 + rate_discount)^yr * (1 - rate_degradation)^(yr - 1)
    end
    den = annuity(years, rate_escalation, rate_discount)

    return num/den
end


function effective_cost(;
    itc_basis::Real, 
    replacement_cost::Real, 
    replacement_year::Int,
    discount_rate::Real, 
    tax_rate::Real, 
    itc::Real,
    macrs_schedule::Array{Float64,1}, 
    macrs_bonus_fraction::Real, 
    macrs_itc_reduction::Real,
    rebate_per_kw::Real=0.0,
    )

    """ effective PV and battery prices with ITC and depreciation
        (i) depreciation tax shields are inherently nominal --> no need to account for inflation
        (ii) ITC and bonus depreciation are taken at end of year 1
        (iii) battery & generator replacement cost: one time capex in user defined year discounted back to t=0 with r_owner
        (iv) Assume that cash incentives reduce ITC basis
        (v) Assume cash incentives are not taxable, (don't affect tax savings from MACRS)
        (vi) Cash incentives should be applied before this function into "itc_basis".
             This includes all rebates and percentage-based incentives besides the ITC
    """

    # itc reduces depreciable_basis
    depr_basis = itc_basis * (1 - macrs_itc_reduction * itc)

    # Bonus depreciation taken from tech cost after itc reduction ($/kW)
    bonus_depreciation = depr_basis * macrs_bonus_fraction

    # Assume the ITC and bonus depreciation reduce the depreciable basis ($/kW)
    depr_basis -= bonus_depreciation

    # Calculate replacement cost, discounted to the replacement year accounting for tax deduction
    replacement = replacement_cost * (1-tax_rate) / ((1 + discount_rate)^replacement_year)

    # Compute savings from depreciation and itc in array to capture NPV
    tax_savings_array = [0.0]
    for (idx, macrs_rate) in enumerate(macrs_schedule)
        depreciation_amount = macrs_rate * depr_basis
        if idx == 1
            depreciation_amount += bonus_depreciation
        end
        taxable_income = depreciation_amount
        push!(tax_savings_array, taxable_income * tax_rate)
    end

    # Add the ITC to the tax savings
    tax_savings_array[2] += itc_basis * itc

    # Compute the net present value of the tax savings
    tax_savings = npv(discount_rate, tax_savings_array)

    # Adjust cost curve to account for itc and depreciation savings ($/kW)
    cap_cost_slope = itc_basis - tax_savings + replacement - rebate_per_kw

    # Sanity check
    if cap_cost_slope < 0
        cap_cost_slope = 0
    end

    return round(cap_cost_slope, digits=4)
end


function dictkeys_tosymbols(d::Dict)
    d2 = Dict()
    for (k, v) in d
        # handling array type conversions for API inputs and JSON
        if k in [
            "loads_kw", "critical_loads_kw",
            "thermal_loads_ton",
            "fuel_loads_mmbtu_per_hour",
            "monthly_totals_kwh",
            "production_factor_series", 
            "monthly_energy_rates", "monthly_demand_rates",
            "blended_doe_reference_percents",
            "coincident_peak_load_charge_per_kw",
            "grid_draw_limit_kw_by_time_step", "export_limit_kw_by_time_step",
            "outage_probabilities",
            "emissions_factor_series_lb_CO2_per_kwh",
            "emissions_factor_series_lb_NOx_per_kwh", 
            "emissions_factor_series_lb_SO2_per_kwh",
            "emissions_factor_series_lb_PM25_per_kwh",
            #for ERP
            "pv_production_factor_series", "battery_starting_soc_series_fraction"
        ] && !isnothing(v)
            try
                v = convert(Array{Real, 1}, v)
            catch
                throw(@error("Unable to convert $k to an Array{Real, 1}"))
            end
        end
        if k in [
            "blended_doe_reference_names"
        ]
            try
                v = convert(Array{String, 1}, v)
            catch
                throw(@error("Unable to convert $k to an Array{String, 1}"))
            end
        end
        if k in [
            "coincident_peak_load_active_time_steps"
        ]
            try
                v = convert(Vector{Vector{Int64}}, v)
            catch
                throw(@error("Unable to convert $k to a Vector{Vector{Int64}}"))
            end
        end
        if k in [
            "outage_start_time_steps", "outage_durations"
        ]
            try
                v = convert(Array{Int64, 1}, v)
            catch
                throw(@error("Unable to convert $k to a Array{Int64, 1}"))
            end
        end
        if k in [
            "fuel_limit_is_per_generator" #for ERP
        ]
            if !(typeof(v) <: Bool)
                try
                    v = convert(Array{Bool, 1}, v)
                catch
                    throw(@error("Unable to convert $k to a Array{Bool, 1}"))
                end
            end
        end
        if k in [
            "fuel_cost_per_mmbtu", "wholesale_rate",
            # for ERP
            "generator_size_kw", "generator_operational_availability",
            "generator_failure_to_start", "generator_mean_time_to_failure",
            "generator_fuel_intercept_per_hr", "generator_fuel_burn_rate_per_kwh",
            "fuel_limit"
        ] && !isnothing(v)
            #if not a Real try to convert to an Array{Real} 
            if !(typeof(v) <: Real)
                try
                    v = convert(Array{Real, 1}, v)
                catch
                    throw(@error("Unable to convert $k to a Array{Real, 1} or Real"))
                end
            end
        end
        if k in [
            "num_generators" #for ERP
        ]
            #if not a Real try to convert to an Array{Real} 
            if !(typeof(v) <: Int)
                try
                    v = convert(Array{Int64, 1}, v)
                catch
                    throw(@error("Unable to convert $k to a Array{Int64, 1} or Int"))
                end
            end
        end
        if k in ["generator_operational_availability", "generator_failure_to_start", "generator_mean_time_to_failure", 
                                "num_generators", "generator_size_kw", "fuel_limit", "fuel_limit_is_per_generator", 
                                "generator_fuel_intercept_per_hr", "generator_fuel_burn_rate_per_kwh"] &&
                                !(typeof(v) <: Array)
            v = [v]
        end
        d2[Symbol(k)] = v
    end
    return d2
end


function filter_dict_to_match_struct_field_names(d::Dict, s::DataType)
    f = fieldnames(s)
    d2 = Dict()
    for k in f
        if haskey(d, k)
            d2[k] = d[k]
        else
            @debug "dict is missing struct field $k"
        end
    end
    return d2
end


function npv(rate::Real, cash_flows::Array)
    npv = cash_flows[1]
    for (y, c) in enumerate(cash_flows[2:end])
        npv += c/(1+rate)^y
    end
    return npv
end


"""
    per_hour_value_to_time_series(x::T, time_steps_per_hour::Int) where T <: Real

Convert a per hour value (eg. dollars/kWh) to time series that matches the settings.time_steps_per_hour
"""
function per_hour_value_to_time_series(x::T, time_steps_per_hour::Int, name::String) where T <: Real
    repeat([x / time_steps_per_hour], 8760 * time_steps_per_hour)
end


"""
    per_hour_value_to_time_series(x::AbstractVector{<:Real}, time_steps_per_hour::Int, name::String)

Convert a monthly or time-sensitive per hour value (eg. dollars/kWh) to a time series that matches the 
settings.time_steps_per_hour.
"""
function per_hour_value_to_time_series(x::AbstractVector{<:Real}, time_steps_per_hour::Int, name::String)
    if length(x) == 8760 * time_steps_per_hour
        return x
    end
    vals = Real[]
    if length(x) == 12  # assume monthly values
        for mth in 1:12
            append!(vals, repeat(
                [x[mth] / time_steps_per_hour], 
                time_steps_per_hour * 24 * daysinmonth(Date("2017-" * string(mth)))
                )
            )
        end
        return vals
    end
    throw(@error("Cannot convert $name to appropriate length time series."))
end

"""
    generate_year_profile_hourly(year::Int64, consecutive_periods::AbstractVector{Dict})

This function creates a year-specific hourly (8760) profile with 1.0 value for time_steps which are defined in `consecutive_periods` based on
    relative (non-year specific) datetime metrics. All other values are 0.0. This functions uses the `Dates` package.

- `year` applies the relative calendar-based `consecutive_periods` to the year's calendar and handles leap years by truncating the last day
- `consecutive_periods` is a list of dictionaries where each dict defines a consecutive period of time which gets a value of 1.0
-- keys for each dict must include "month", "start_week_of_month", "start_day_of_week", "start_hour", "duration_hours
- Returns the `year_profile_hourly` which is an 8760 profile with 1.0 for time_steps defined in consecutive_periods, and 0.0 for all other hours.
"""
function generate_year_profile_hourly(year::Int64, consecutive_periods::AbstractVector{Dict})
    # Create datetime series of the year, remove last day of the year if leap year
    if Dates.isleapyear(year)
        end_year_datetime = DateTime(string(year)*"-12-30T23:00:00")
    else
        end_year_datetime = DateTime(string(year)*"-12-31T23:00:00")
    end

    dt_hourly = collect(DateTime(string(year)*"-01-01T00:00:00"):Hour(1):end_year_datetime)
    
    year_profile_hourly = zeros(8760)

    # Note, day = 1 is Monday, not Sunday
    day_of_week_name = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    for i in eachindex(consecutive_periods)
        start_month = convert(Int,consecutive_periods[i]["month"])
        start_week_of_month = convert(Int,consecutive_periods[i]["start_week_of_month"])
        start_day_of_week = convert(Int,consecutive_periods[i]["start_day_of_week"])  # Monday - Sunday is 1 - 7
        start_hour = convert(Int,consecutive_periods[i]["start_hour"])
        duration_hours = convert(Int,consecutive_periods[i]["duration_hours"])
        error_start_text = "Error in chp.unavailability_period $(i)."
        
        try
            start_date_of_month_year = Date(Dates.Year(year), Dates.Month(start_month))
            start_date = Dates.firstdayofweek(start_date_of_month_year) + Dates.Week(start_week_of_month - 1) + Dates.Day(start_day_of_week - 1)
            # Throw an error if start_date is in the previous month when start_week_of_month=1 and there is no start_day_of_week in the first week of the month.
            if Dates.month(start_date) != start_month
                throw(@error("For $(error_start_text), there is no day $(start_day_of_week) ($(day_of_week_name[start_day_of_week])) in the first week of month $(start_month) ($(Dates.monthname(start_date))), $(year)"))
            end
            start_datetime = Dates.DateTime(start_date) + Dates.Hour(start_hour - 1)
            if Dates.year(start_datetime + Dates.Hour(duration_hours)) > year
                throw(@error("For $(error_start_text), the start day/time and duration_hours exceeds the end of the year. Please specify two separate unavailability periods: one for the beginning of the year and one for up to the end of the year."))
            else
                #end_datetime is the last hour that is 1.0 (e.g. that is still unavailable), not the first hour that is 0.0 after the period
                end_datetime = start_datetime + Dates.Hour(duration_hours - 1)
                year_profile_hourly[findfirst(x->x==start_datetime, dt_hourly):findfirst(x->x==end_datetime, dt_hourly)] .= 1.0
            end
        catch e
            println("For $error_start_text, invalid set for month $start_month (1-12), start_week_of_month $start_week_of_month (1-4, possible 5 and 6), $start_day_of_week (1-7), and $start_hour (1-24) for the year $year.")
        end
    end
    return year_profile_hourly
end


"""
    call_pvwatts_api(latitude::Real, longitude::Real; tilt=latitude, azimuth=180, module_type=0, array_type=1, 
        losses=14, dc_ac_ratio=1.2, gcr=0.4, inv_eff=96, timeframe="hourly", radius=0, time_steps_per_hour=1)
This calls the PVWatts API and returns both:
 - PV production factor
 - Ambient outdoor air dry bulb temperature profile [Celcius] 
"""
function call_pvwatts_api(latitude::Real, longitude::Real; tilt=latitude, azimuth=180, module_type=0, array_type=1, 
    losses=14, dc_ac_ratio=1.2, gcr=0.4, inv_eff=96, timeframe="hourly", radius=0, time_steps_per_hour=1)
    # Check if site is beyond the bounds of the NRSDB TMY dataset. If so, use the international dataset.
    dataset = "nsrdb"
    if longitude < -179.5 || longitude > -21.0 || latitude < -21.5 || latitude > 60.0
        if longitude < 81.5 || longitude > 179.5 || latitude < -60.0 || latitude > 60.0 
            if longitude < 67.0 || latitude < -40.0 || latitude > 38.0
                dataset = "intl"
            end
        end
    end
    url = string("https://developer.nrel.gov/api/pvwatts/v8.json", "?api_key=", nrel_developer_key,
        "&lat=", latitude , "&lon=", longitude, "&tilt=", tilt,
        "&system_capacity=1", "&azimuth=", azimuth, "&module_type=", module_type,
        "&array_type=", array_type, "&losses=", losses, "&dc_ac_ratio=", dc_ac_ratio,
        "&gcr=", gcr, "&inv_eff=", inv_eff, "&timeframe=", timeframe, "&dataset=", dataset,
        "&radius=", radius
        )

    try
        @info "Querying PVWatts for production factor and ambient air temperature... "
        r = HTTP.get(url, keepalive=true, readtimeout=10)
        response = JSON.parse(String(r.body))
        if r.status != 200
            throw(@error("Bad response from PVWatts: $(response["errors"])"))
        end
        @info "PVWatts success."
        # Get both possible data of interest
        watts = collect(get(response["outputs"], "ac", []) / 1000)  # scale to 1 kW system (* 1 kW / 1000 W)
        tamb_celcius = collect(get(response["outputs"], "tamb", []))  # Celcius
        # Validate outputs
        if length(watts) != 8760
            throw(@error("PVWatts did not return a valid prodfactor. Got $watts"))
        end
        # Validate tamb_celcius
        if length(tamb_celcius) != 8760
            throw(@error("PVWatts did not return a valid temperature. Got $tamb_celcius"))
        end 
        # Upsample or downsample based on model time_steps_per_hour
        if time_steps_per_hour > 1
            watts = repeat(watts, inner=time_steps_per_hour)
            tamb_celcius = repeat(tamb_celcius, inner=time_steps_per_hour)
        end
        return watts, tamb_celcius
    catch e
        throw(@error("Error occurred when calling PVWatts: $e"))
    end
end


"""
    Convert gallons of stored liquid (e.g. water, water/glycol) to kWh of stored energy in a stratefied tank
    Note: uses the PropsSI function from the CoolProp package.  Further details on inputs used are available
        at: http://www.coolprop.org/coolprop/HighLevelAPI.html
    :param delta_T_degF: temperature difference between the hot/warm side and the cold side
    :param rho_kg_per_m3: density of the liquid
    :param cp_kj_per_kgK: heat capacity of the liquid
    :return gal_to_kwh: stored energy, in kWh
"""
function get_kwh_per_gal(t_hot_degF::Real, t_cold_degF::Real, fluid::String="Water")
    t_hot_K = convert_temp_degF_to_Kelvin(t_hot_degF)  # [K]
    t_cold_K = convert_temp_degF_to_Kelvin(t_cold_degF)  # [K]
    avg_t_K = (t_hot_K + t_cold_K) / 2.0
    avg_rho_kg_per_m3 = PropsSI("D", "P", 101325.0, "T", avg_t_K, fluid)  # [kg/m^3]
    avg_cp_kj_per_kgK = PropsSI("CPMASS", "P", 101325.0, "T", avg_t_K, fluid) / 1000  # kJ/kg-K
    kj_per_m3 = avg_rho_kg_per_m3 * avg_cp_kj_per_kgK * (t_hot_K - t_cold_K)  # [kJ/m^3]
    kj_per_gal = kj_per_m3 / 264.172   # divide by gal/m^3 to get: [kJ/gal]
    kwh_per_gal = kj_per_gal / 3600.0  # divide by kJ/kWh, i.e., sec/hr, to get: [kWh/gal]
    return kwh_per_gal
end

"""
    The input offgrid_other_capital_costs is considered to be for depreciable assets. 
    Straight line depreciation is applied, and the depreciation expense is assumed to reduce the owner's taxable income
    Depreciation savings are taken at the end of year 1 and are assumed to accumulate for a period equal to analysis_years.
    :return npv_other_capex: present value of tax savings from depreciation of assets included in `offgrid_other_capital_costs`
"""
function get_offgrid_other_capex_depreciation_savings(offgrid_other_capital_costs::Real, discount_rate::Real, 
    analysis_years::Int, tax_rate::Real)
    tax_savings_array = repeat([offgrid_other_capital_costs/analysis_years*tax_rate], analysis_years) 
    prepend!(tax_savings_array, 0.0) # savings taken at end of year 1
    npv_other_capex = npv(discount_rate, tax_savings_array)
    return npv_other_capex
end

macro argname(arg)
    string(arg)
end

"""
    get_monthly_time_steps(year::Int; time_steps_per_hour=1)

return Array{Array{Int64,1},1}, size = (12,)
"""
function get_monthly_time_steps(year::Int; time_steps_per_hour=1)
    a = Array[]
    i = 1
    for m in range(1, stop=12)
        n_days = daysinmonth(Date(string(year) * "-" * string(m)))
        stop = n_days * 24 * time_steps_per_hour + i - 1
        if m == 2 && isleapyear(year)
            stop -= 24 * time_steps_per_hour  # TODO support extra day in leap years?
        end
        steps = [step for step in range(i, stop=stop)]
        append!(a, [steps])
        i = stop + 1
    end
    return a
end

"""
generator_fuel_slope_and_intercept(;
                electric_efficiency_full_load::Real, [kWhe/kWht]
                electric_efficiency_half_load::Real, [kWhe/kWht]
                fuel_higher_heating_value_kwh_per_gal::Real
            )

return Tuple{<:Real,<:Real} where 
    first value is diesel fuel burn slope [gal/kWhe]
    secnod value is diesel fuel burn intercept [gal/hr]
"""
function generator_fuel_slope_and_intercept(;
                        electric_efficiency_full_load::Real, 
                        electric_efficiency_half_load::Real,
                        fuel_higher_heating_value_kwh_per_gal::Real
                    )
    fuel_burn_full_load_kwht = 1.0 / electric_efficiency_full_load  # [kWe_rated/(kWhe/kWht)]
    fuel_burn_half_load_kwht = 0.5 / electric_efficiency_half_load  # [kWe_rated/(kWhe/kWht)]
    fuel_slope_kwht_per_kwhe = (fuel_burn_full_load_kwht - fuel_burn_half_load_kwht) / (1.0 - 0.5)  # [kWht/kWhe]
    fuel_intercept_kwht_per_hr = fuel_burn_full_load_kwht - fuel_slope_kwht_per_kwhe * 1.0  # [kWht/hr]
    fuel_slope_gal_per_kwhe = fuel_slope_kwht_per_kwhe / fuel_higher_heating_value_kwh_per_gal # [gal/kWhe]
    fuel_intercept_gal_per_hr = fuel_intercept_kwht_per_hr / fuel_higher_heating_value_kwh_per_gal # [gal/hr]
    
    return fuel_slope_gal_per_kwhe, fuel_intercept_gal_per_hr
end

function convert_temp_degF_to_Kelvin(degF::Float64)
    return (degF - 32) * 5.0 / 9.0 + 273.15
end
