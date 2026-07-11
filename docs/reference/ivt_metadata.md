# Read only the metadata of an IVT file (no value decoding)

Much faster than
[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)
when you only need the codebook: table identity, dimension members,
geographic identifiers (names + DGUIDs) and footnotes.

## Usage

``` r
ivt_metadata(path)
```

## Arguments

- path:

  Path to an `.ivt` file.

## Value

A list of metadata (see
[`read_ivt()`](https://mountainmath.github.io/canivt/reference/read_ivt.md)).

## Examples

``` r
path <- system.file("extdata", "98100044.ivt", package = "canivt")
meta <- ivt_metadata(path)
meta$dimensions
#> [[1]]
#> [[1]]$name
#> [1] "Geography"
#> 
#> [[1]]$name_fr
#> [1] NA
#> 
#> [[1]]$count
#> [1] 14
#> 
#> [[1]]$type
#> [1] 4
#> 
#> [[1]]$is_geography
#> [1] TRUE
#> 
#> [[1]]$members
#> NULL
#> 
#> [[1]]$members_fr
#> NULL
#> 
#> [[1]]$ordinal
#> NULL
#> 
#> 
#> [[2]]
#> [[2]]$name
#> [1] "Type of collective dwelling"
#> 
#> [[2]]$name_fr
#> [1] "Type de logement collectif"
#> 
#> [[2]]$count
#> [1] 16
#> 
#> [[2]]$type
#> [1] 4
#> 
#> [[2]]$is_geography
#> [1] FALSE
#> 
#> [[2]]$members
#>  [1] "Total - Type of collective dwelling"                                                             
#>  [2] "  Health care and related facilities"                                                            
#>  [3] "    Hospitals"                                                                                   
#>  [4] "    Nursing homes"                                                                               
#>  [5] "    Residences for senior citizens"                                                              
#>  [6] "    Facilities that are a mix of both a nursing home and a residence for senior citizens"        
#>  [7] "    Residential care facilities such as group homes for persons with disabilities and addictions"
#>  [8] "  Correctional and custodial facilities"                                                         
#>  [9] "  Shelters"                                                                                      
#> [10] "  Service collective dwellings"                                                                  
#> [11] "    Lodging and rooming houses"                                                                  
#> [12] "    Hotels, motels and other establishments with temporary accommodation services"               
#> [13] "    Other service collective dwellings"                                                          
#> [14] "  Religious establishments"                                                                      
#> [15] "  Hutterite colonies"                                                                            
#> [16] "  Other collective dwellings"                                                                    
#> 
#> [[2]]$members_fr
#>  [1] "Total - Type de logement collectif"                                                                                                    
#>  [2] "  Établissements de soins de santé et établissements connexes"                                                                         
#>  [3] "    Hôpitaux"                                                                                                                          
#>  [4] "    Établissements de soins infirmiers"                                                                                                
#>  [5] "    Résidences pour personnes âgées"                                                                                                   
#>  [6] "    Établissements qui sont une combinaison d’un établissement de soins infirmiers et d’une résidence pour personnes âgées"            
#>  [7] "    Établissements de soins pour bénéficiaires internes comme un foyer collectif pour personnes ayant une incapacité ou une dépendance"
#>  [8] "  Établissements correctionnels et de détention"                                                                                       
#>  [9] "  Refuges"                                                                                                                             
#> [10] "  Logements collectifs offrant des services"                                                                                           
#> [11] "    Maisons de chambres et pensions"                                                                                                   
#> [12] "    Hôtels, motels et autres établissements offrant des services d'hébergement temporaire"                                             
#> [13] "    Autres logements collectifs offrant des services"                                                                                  
#> [14] "  Établissements religieux"                                                                                                            
#> [15] "  Colonies huttérites"                                                                                                                 
#> [16] "  Autres logements collectifs"                                                                                                         
#> 
#> [[2]]$ordinal
#>  [1]  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
#> 
#> 
#> [[3]]
#> [[3]]$name
#> [1] "Collective dwellings occupied by usual residents and population in collective dwellings"
#> 
#> [[3]]$name_fr
#> [1] NA
#> 
#> [[3]]$count
#> [1] 2
#> 
#> [[3]]$type
#> [1] 18
#> 
#> [[3]]$is_geography
#> [1] FALSE
#> 
#> [[3]]$members
#> [1] "Collective dwellings occupied by usual residents"
#> [2] "Population in collective dwellings"              
#> 
#> [[3]]$members_fr
#> [1] "Logements collectifs occupés par des résidents habituels"
#> [2] "Population dans les logements collectifs"                
#> 
#> [[3]]$ordinal
#> [1] 1 2
#> 
#> 
```
