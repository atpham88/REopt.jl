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

#Renewable electricity constraints
function add_re_elec_constraints(m,p)
	if !isnothing(p.s.site.renewable_electricity_min_pct)
		@constraint(m, MinREElecCon, m[:AnnualREEleckWh] >= p.s.site.renewable_electricity_min_pct*m[:AnnualEleckWh])
	end
	if !isnothing(p.s.site.renewable_electricity_max_pct)
		@constraint(m, MaxREElecCon, m[:AnnualREEleckWh] <= p.s.site.renewable_electricity_max_pct*m[:AnnualEleckWh])
	end
end

# Renewable electricity calculation
function add_re_elec_calcs(m,p)
	
	# User-selected RE electricity accounting methodology:
	if p.s.site.include_exported_renewable_electricity_in_total
		include_exported_re_elec_in_total = 1
	else
		include_exported_re_elec_in_total = 0
	end

	# TODO: When steam turbine implemented, uncomment code below, replacing p.TechCanSupplySteamTurbine, p.STElecOutToThermInRatio with new names
	# # Steam turbine RE elec calculations 
	# if isempty(p.steam)
	# 	SteamTurbineAnnualREEleckWh = 0 
    # else  
	# 	# Note: SteamTurbine's input p.tech_renewable_energy_pct = 0 because it is actually a decision variable dependent on fraction of steam generated by RE fuel
	# 	SteamTurbinePercentREEstimate = @expression(m,
	# 		sum(p.tech_renewable_energy_pct[tst] for tst in p.TechCanSupplySteamTurbine) / length(p.TechCanSupplySteamTurbine)
	# 	)
	# 	# Note: Steam turbine battery losses, curtailment, and exported RE terms are only accurate if all techs that can supply ST 
	# 	#		have equal RE%, otherwise it is an approximation because the general equation is non linear. 
	# 	SteamTurbineAnnualREEleckWh = @expression(m,p.hours_per_timestep * (
	# 		p.STElecOutToThermInRatio * sum(m[:dvThermalToSteamTurbine][tst,ts]*p.tech_renewable_energy_pct[tst] for ts in p.time_steps, tst in p.TechCanSupplySteamTurbine) # plus steam turbine RE generation 
	# 		- sum(m[:dvProductionToStorage][b,t,ts] * SteamTurbinePercentREEstimate * (1-p.s.storage.attr[b].charge_efficiency*p.s.storage.attr[b].discharge_efficiency) for t in p.steam, b in p.s.storage.types.elec, ts in p.time_steps) # minus battery storage losses from RE from steam turbine
	# 		- sum(m[:dvCurtail][t,ts] * SteamTurbinePercentREEstimate for t in p.steam, ts in p.time_steps) # minus curtailment.
	# 		- (1-include_exported_re_elec_in_total)*sum(m[:dvProductionToGrid][t,u,ts]*SteamTurbinePercentREEstimate for t in p.steam,  u in p.export_bins_by_tech[t], ts in p.time_steps) # minus exported RE from steam turbine, if RE accounting method = 0.
	# 	))
	# end

	m[:AnnualREEleckWh] = @expression(m,p.hours_per_timestep* (
			sum(p.production_factor[t,ts] * p.levelization_factor[t] * m[:dvRatedProduction][t,ts] * p.tech_renewable_energy_pct[t] for t in p.techs.elec, ts in p.time_steps) #total RE elec generation, excl steam turbine
			- sum(m[:dvProductionToStorage][b,t,ts]*p.tech_renewable_energy_pct[t]*(1-p.s.storage.attr[b].charge_efficiency*p.s.storage.attr[b].discharge_efficiency) for t in p.techs.elec, b in p.s.storage.types.elec, ts in p.time_steps) #minus battery efficiency losses
			- sum(m[:dvCurtail][t,ts]*p.tech_renewable_energy_pct[t] for t in p.techs.elec, ts in p.time_steps) # minus curtailment.
			- (1-include_exported_re_elec_in_total)*sum(m[:dvProductionToGrid][t,u,ts]*p.tech_renewable_energy_pct[t] for t in p.techs.elec,  u in p.export_bins_by_tech[t], ts in p.time_steps) # minus exported RE, if RE accounting method = 0.
		)
		# + SteamTurbineAnnualREEleckWh  # SteamTurbine RE Elec, already adjusted for p.hours_per_timestep
	)
		
    # Note: if battery ends up being allowed to discharge to grid, need to make sure only RE that is being consumed onsite is counted so battery doesn't become a back door for RE to grid.
	# Note: calculations currently do not ascribe any renewable energy attribute to grid-purchased electricity

	m[:AnnualEleckWh] = @expression(m,p.hours_per_timestep*(
			sum(p.s.electric_load.loads_kw[ts] for ts in p.time_steps) # input elec load
			# + sum(m[:dvThermalProduction][t,ts] for t in p.ElectricChillers, ts in p.time_steps )/ p.ElectricChillerCOP # electric chiller elec load
			# + sum(m[:dvThermalProduction][t,ts] for t in p.AbsorptionChillers, ts in p.time_steps )/ p.AbsorptionChillerElecCOP # absorportion chiller elec load
			# + sum(p.GHPElectricConsumed[g,ts] * m[:binGHP][g] for g in p.GHPOptions, ts in p.time_steps) # GHP elec load
		)
	)

end

#Renewable heat calculations and totalling heat/electric emissions
function add_re_tot_calcs(m,p)
 
	if !isempty(p.techs.heating)
		# TODO: When steam turbine implemented, uncomment code below, replacing p.TechCanSupplySteamTurbine, p.STElecOutToThermInRatio, p.STThermOutToThermInRatio with new names
		# # Steam turbine RE heat calculations
		# if isempty(p.steam)
		# 	AnnualSteamTurbineREThermOut = 0 
		# 	AnnualRESteamToSteamTurbine = 0
		# 	AnnualSteamToSteamTurbine = 0
		# else  
		# 	# Note: SteamTurbine's input p.tech_renewable_energy_pct = 0 because it is actually a decision variable dependent on fraction of steam generated by RE fuel
		# 	# SteamTurbine RE battery losses, RE curtailment, and exported RE terms are based on an approximation of percent RE because the general equation is nonlinear
		# 	# Thus, SteamTurbine %RE is only accurate if all techs that can supply ST have equal %RE fuel or provide equal quantities of steam to the steam turbine
		# 	SteamTurbinePercentREEstimate = @expression(m,
		# 		sum(p.tech_renewable_energy_pct[tst] for tst in p.TechCanSupplySteamTurbine) / length(p.TechCanSupplySteamTurbine)
		# 	)
		# 	AnnualSteamTurbineREThermOut = @expression(m,p.hours_per_timestep *
		# 		p.STThermOutToThermInRatio * sum(m[:dvThermalToSteamTurbine][tst,ts]*p.tech_renewable_energy_pct[tst] for ts in p.time_steps, tst in p.TechCanSupplySteamTurbine) # plus steam turbine RE generation 
		# 		- sum(m[:dvProductionToStorage][b,t,ts] * SteamTurbinePercentREEstimate * (1-p.s.storage.attr[b].charge_efficiency*p.s.storage.attr[b].discharge_efficiency) for t in p.steam, b in p.HotTES, ts in p.time_steps) # minus battery storage losses from RE heat from steam turbine; note does not account for p.DecayRate
		# 	)
		# 	AnnualRESteamToSteamTurbine = @expression(m,p.hours_per_timestep *
		# 		sum(m[:dvThermalToSteamTurbine][tst,ts]*p.tech_renewable_energy_pct[tst] for ts in p.time_steps, tst in p.TechCanSupplySteamTurbine) # steam to steam turbine from other techs- need to subtract this out from the total 	
		# 	)
		# 	AnnualSteamToSteamTurbine = @expression(m,p.hours_per_timestep *
		# 		sum(m[:dvThermalToSteamTurbine][tst,ts] for ts in p.time_steps, tst in p.TechCanSupplySteamTurbine) # steam to steam turbine from other techs- need to subtract this out from the total
		# 	)
		# end

		# Renewable heat (RE steam/hot water heat that is not being used to generate electricity)
		AnnualREHeatkWh = @expression(m,p.hours_per_timestep*(
				sum(p.production_factor[t,ts] * p.levelization_factor[t] * m[:dvThermalProduction][t,ts] * p.tech_renewable_energy_pct[t] for t in p.techs.heating, ts in p.time_steps) #total RE heat generation (excl steam turbine, GHP)
				- sum(m[:dvProductionToWaste][t,ts]* p.tech_renewable_energy_pct[t] for t in p.techs.chp, ts in p.time_steps) #minus CHP waste heat
				+ sum(m[:dvSupplementaryThermalProduction][t,ts] * p.tech_renewable_energy_pct[t] for t in p.techs.chp, ts in p.time_steps) # plus CHP supplemental firing thermal generation
				- sum(m[:dvProductionToStorage][b,t,ts]*p.tech_renewable_energy_pct[t]*(1-p.s.storage.attr[b].charge_efficiency*p.s.storage.attr[b].discharge_efficiency) for t in p.techs.heating, b in p.HotTES, ts in p.time_steps) #minus thermal storage losses, note does not account for p.DecayRate
			)
			# - AnnualRESteamToSteamTurbine # minus RE steam feeding steam turbine, adjusted by p.hours_per_timestep 
			# + AnnualSteamTurbineREThermOut #plus steam turbine RE generation, adjusted for storage losses, adjusted by p.hours_per_timestep (not included in first line because p.tech_renewable_energy_pct for SteamTurbine is 0)
		)

		# Total heat (steam/hot water heat that is not being used to generate electricity)
		AnnualHeatkWh = @expression(m,p.hours_per_timestep*(
				sum(p.production_factor[t,ts] * p.levelization_factor[t] * m[:dvThermalProduction][t,ts] for t in p.techs.heating, ts in p.time_steps) #total heat generation (need to see how GHP fits into this)
				- sum(m[:dvProductionToWaste][t,ts] for t in p.techs.chp, ts in p.time_steps) #minus CHP waste heat
				+ sum(m[:dvSupplementaryThermalProduction][t,ts] for t in p.techs.chp, ts in p.time_steps) # plus CHP supplemental firing thermal generation
				# - sum(m[:dvProductionToStorage][b,t,ts]*(1-p.s.storage.attr[b].charge_efficiency*p.s.storage.attr[b].discharge_efficiency) for t in p.techs.heating, b in p.HotTES, ts in p.time_steps) #minus thermal storage losses
			)
			# - AnnualSteamToSteamTurbine # minus steam going to SteamTurbine; already adjusted by p.hours_per_timestep
		)
	else
		AnnualREHeatkWh = 0 
		AnnualHeatkWh = 0
	end 
	m[:AnnualRETotkWh] = @expression(m,m[:AnnualREEleckWh] + AnnualREHeatkWh)
	m[:AnnualTotkWh] = @expression(m,m[:AnnualEleckWh] + AnnualHeatkWh)
	
end