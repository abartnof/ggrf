# ELT on Zillow data, and link turbines to zip-codes

# Perform the kinds of essential ELT that has to happen (eg matching locations
# of turbines to zip-codes), but leave feature engineering 
# (eg leaving observations as-is, or aggregating them) to the individual model 
# scripts.

library(tidyverse)
library(skimr)
library(arrow)
library(sf)

epsg_standard <- 4326  # Conform all coordinates to this projection

fn_zillow <- '/Volumes/Extreme SSD/ggrf_insurance/input_data/zillow_sm_sa_month.csv'
fn_zillow_clean <- '/Volumes/Extreme SSD/ggrf_insurance/clean_data_2/zillow_clean.parquet'
fn_zillow_delta <-'/Volumes/Extreme SSD/ggrf_insurance/clean_data_2/zillow_delta.parquet'

fn_turbines <- '/Volumes/Extreme SSD/ggrf_insurance/input_data/uswtdbSHP/uswtdb_V8_0_20250225.shp'
fn_turbines_out <- '/Volumes/Extreme SSD/ggrf_insurance/clean_data_2/turbines.parquet'

fn_zips <- '/Volumes/Extreme SSD/ggrf_insurance/input_data/zcta/tl_2020_us_zcta520.shp'

# Read Zillow data-- add a row for observation_id, and keep only zip-code and
# house price on a given date. Convert this to 'long' format.

Zillow <- read_csv(fn_zillow)

ZillowClean <-
	Zillow %>%
	rowid_to_column('zillow_observation_id') %>%
	select(-RegionID, -SizeRank, -RegionType, -StateName, -State, -City, -Metro, -CountyName) %>%
	rename(zip_code = RegionName) %>%
	gather(date, home_price, -zillow_observation_id, -zip_code) %>%
	mutate(
		date = lubridate::ymd(date),
	)

ZillowYearlyMedianHomePrices <-
	ZillowClean %>%
	drop_na %>%
	mutate(
		date = lubridate::round_date(date, 'year'),
		year = lubridate::year(date),
		year = as.integer(year)
		) %>%
	group_by(zip_code, year) %>%
	summarize(median_home_price = median(home_price)) %>%
	ungroup

ZillowYearlyMedianHomePrices %>% 
	is.na %>% 
	colSums()

# Now calculate year over year change in home prices
year_range <- seq(min(ZillowYearlyMedianHomePrices$year), max(ZillowYearlyMedianHomePrices$year))

CteZillowDelta <-
	expand_grid(
		year = year_range,
		zip_code = unique(ZillowClean$zip_code)
	) %>%
	left_join(ZillowYearlyMedianHomePrices, by = c('year', 'zip_code')) %>%
	arrange(zip_code, year) %>%
	group_by(zip_code) %>%
	mutate(
		prev_value = lag(median_home_price),
		delta = (median_home_price - prev_value)/prev_value
	) %>%
	ungroup

ZillowDelta <-
	CteZillowDelta %>%
	select(year, zip_code, delta) %>%
	drop_na
#	

ZillowDelta %>% write_parquet(fn_zillow_delta)
ZillowClean %>% write_parquet(fn_zillow_clean)

# Turbines
# Note each turbine's unique id; convert year of operation to a 'date' object;
# save long and lat
# Note that this for-loop deals with GIS data so it takes a while to run.

Turbines <- sf::read_sf(fn_turbines)
Turbines <- st_transform(Turbines, crs = epsg_standard)
TurbinesClean <-
	Turbines %>%
	select(case_id, p_year, geometry) %>%
	rename(turbine_id = case_id, turbine_year_of_operation = p_year, turbine_coords = geometry) %>%
	mutate(
		turbine_date_of_operation = lubridate::ymd(str_c(turbine_year_of_operation), truncated = 2L),
		turbine_id = factor(turbine_id, ordered = FALSE)
	) %>%
	relocate(turbine_id, turbine_date_of_operation, turbine_coords) %>%
	arrange(turbine_id, turbine_date_of_operation)

TurbinePoints <-
	Turbines %>%
	select(case_id) %>%
	st_centroid() %>%
	rename(turbine_case_id = case_id, turbine_centroid = geometry)

# Zip Codes- convert to centroids

Zips <- sf::read_sf(fn_zips)
Zips <- st_transform(Zips, crs = epsg_standard)
ZipPoints <-
	Zips %>%
	select(ZCTA5CE20) %>%
	rename(zip_code = ZCTA5CE20, zip_point = geometry) %>%
	st_centroid()

#	Iterate through each turbine, note the zip code centroid that's closest.
# Record these zip codes in a list
# NB this takes a few hours.
matches_list <- rep('', nrow(TurbinePoints))
for (i in seq(1, nrow(TurbinePoints))){
	print(sprintf('%i of %i: %.3f', i, nrow(TurbinePoints), i / nrow(TurbinePoints)))
	target_turbine <- TurbinePoints$turbine_case_id[i]
	g1 <- TurbinePoints %>% slice(i)
	
	# find the index of the min. distance
	distance <- st_distance(g1, ZipPoints, by_element = FALSE)
	j <- which.min(distance)
	matched_zip_code <- ZipPoints$zip_code[j]
	
	# Store best zip code in list at position i
	matches_list[i] <- matched_zip_code
}
TurbinesMatched <-
	TurbinesClean %>%
	st_drop_geometry() %>%
	select(turbine_id, turbine_date_of_operation) %>%
	bind_cols(zip_code = matches_list)
TurbinesMatched %>% write_parquet(fn_turbines_out)