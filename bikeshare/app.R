
library(shiny)
library(leaflet)
library(plotly)
library(leaflet.extras)
library(DT)
library(rgdal)# readOGR
library(tidyverse)
library(tigris) # to merge spatial data with demographic information
library(httr) # http rest requests
library(jsonlite) # fromJSON
library(utils) # URLencode functions
library(sp)
library(sf)
library(shinydashboard)


# Accessing Data and Pre-Processing ---------------------------------------------------------------------------------------------------------

#Loading in the Pittsburgh HealthyRide Stations data using WPRDC API
# URL Encode the query
q <- 'SELECT * FROM "395ca98e-75a4-407b-9b76-d2519da28c4a"'
formatQuery <- URLencode(q, repeated = TRUE)
# Build URL for GET request
url <- paste0("https://data.wprdc.org/api/3/action/datastore_search_sql?sql=", formatQuery)
# Run Get Request
g <- GET(url)
stations <- fromJSON(content(g, "text"))$result$records

#subsetting data to desired columns
stations <- stations %>% 
    select("Station #","Station Name", "Latitude", "Longitude", "# of Racks") %>% 
    mutate("# of Racks" = as.factor(`# of Racks`),
           "# of Racks" = as.numeric(`# of Racks`))

#changing the datatypes for some of the columns in the stations dataset
options(digits=6)

stations <- stations %>% 
    mutate(Longitude = as.numeric(Longitude),
           Latitude = as.numeric(Latitude),
           `# of Racks` = as.numeric(`# of Racks`))

#loading in the shapefile with Pittsburgh neighborhoods
pitt_census_tracts <- rgdal::readOGR("~/Documents/GitHub/final_toj/2010_Census_Tracts.geojson")

pitt_demog <- read.csv("~/Documents/GitHub/final_toj/pitt_demographics_by_census_tract.csv")
demog_filtered <-
    pitt_demog %>%
    rename(census.tract = Label) %>%
    filter(grepl("Census Tract", census.tract) | grepl("Estimate", census.tract)) %>%  #filtering to only include rows containing the words "census tract"
    mutate_at(-1, ~lead(., 1))

#now that the data has been shifted up by one row, remove the empty row
toDelete <- seq(0,nrow(demog_filtered),2)

#remove the undesired rows from the dataframe
demog_filtered <- demog_filtered[-toDelete,]

#update the formatting of the census tract column to match the shapefile data 
demog_filtered <- demog_filtered %>%
    mutate(census.tract = as.character(census.tract),
           census.tract = parse_number(census.tract),
           census.tract = round(census.tract, digits = 0),
           census.tract = as.character(census.tract),
           census.tract = ifelse(nchar(census.tract) == 3, paste0("0", census.tract, "00"), paste0(census.tract, "00")))

#changes the census tract column in the shapefile dataset to be a character
pitt_census_tracts$tractce10 <- as.character(pitt_census_tracts$tractce10)


#only include the census tracts for pittsburgh by filtering based on the pittsburgh census info
pitt_demog_info <-
    demog_filtered %>%
    filter(census.tract %in% pitt_census_tracts$tractce10)

#getting rid of empty "RACE" column
pitt_demog_info <- pitt_demog_info[,-2]

#changes demographic info columns to numbers instead of characters
pitt_demog_info <- pitt_demog_info %>%
    mutate_if(is.factor, as.character) %>%
    mutate_all(funs(str_replace(., ",", ""))) %>%
    mutate_at(names(pitt_demog_info)[-1], as.numeric)

#selects desired columns and renames columns
pitt_demog_info <-
  pitt_demog_info %>%
  select(census.tract, RACE..Total.population, RACE..Total.population..One.race..White, RACE..Total.population..One.race..Black.or.African.American, RACE..Total.population..One.race..American.Indian.and.Alaska.Native, RACE..Total.population..One.race..Asian, HISPANIC.OR.LATINO.AND.RACE..Total.population..Hispanic.or.Latino..of.any.race.) %>%
  rename("Total Population" = RACE..Total.population,
         "Number of White Residents" = RACE..Total.population..One.race..White,
         "Number of Black Residents" = RACE..Total.population..One.race..Black.or.African.American,
         "Number of American Indian Residents" = RACE..Total.population..One.race..American.Indian.and.Alaska.Native,
         "Number of Asian Residents" = RACE..Total.population..One.race..Asian,
         "Number of Hispanic/Latino Residents" = HISPANIC.OR.LATINO.AND.RACE..Total.population..Hispanic.or.Latino..of.any.race.)


#creates new columns
pitt_demog_info <- pitt_demog_info %>%
  mutate("Percentage of White Residents" = ifelse(`Number of White Residents` != 0,round((`Number of White Residents`/`Total Population`)*100, digits = 2), 0),
         "Percentage of Black Residents" = ifelse(`Number of Black Residents` != 0,round((`Number of Black Residents`/`Total Population`)*100, digits = 2), 0),
         "Percentage of American Indian Residents" = ifelse(`Number of American Indian Residents` != 0,round((`Number of American Indian Residents`/`Total Population`)*100, digits = 2), 0),
         "Percentage of Asian Residents" = ifelse(`Number of Asian Residents` != 0,round((`Number of Asian Residents`/`Total Population`)*100, digits = 2), 0),
         "Percentage of Hispanic/Latino Residents" = ifelse(`Number of Hispanic/Latino Residents` != 0,round((`Number of Hispanic/Latino Residents`/`Total Population`)*100, digits = 2), 0)
  )



#merging census shape files and demographic information
census_and_demog <- geo_join(pitt_census_tracts,
                             pitt_demog_info, by_sp = "tractce10", by_df = "census.tract", how = "left")



#counting the number of bikeshare stations in each census tract

#convert the stations data into a spatial dataframe
stations_spatial <-
  stations %>%
  st_as_sf(coords = c("Longitude", "Latitude"), crs = 4326) %>%
  as_Spatial()


#count the number of bikeshare stations within the census tract polygons
num.stations.per.tract <- GISTools::poly.counts(stations_spatial, census_and_demog)

#adding data about overlaps to the census and demog dataset
census_and_demog@data$num.stations.per.tract <- num.stations.per.tract




#Start creating the dashboard --------------------------------------------------------------------------------------------------------------------


#Dashboard Header & Title-----------------------------------------------------------
header <- dashboardHeader(title = "Is Bike Share Access Equitably Distributed In Pittsburgh?",
                         titleWidth = 600)


#Dashboard Sidebar -----------------------------------------
sidebar <- dashboardSidebar(
  sidebarMenu(
    id = "tabs",
    
    #Menu Items ----------------------------------------
    menuItem("Map Overview", icon = icon("map-marked"), tabName = "overview"),
    menuItem("Bike Share Distribution", icon = icon("bicycle"), tabName = "bikes"),
    menuItem("Full Demographics Dataset", icon = icon("table"), tabName = "fullData")
  )
)


#Dashboard body -------------------------------------
body <- dashboardBody(tabItems(
  
  #Overview page ----------------------------------
  tabItem("overview",
          
          #select input for the demographic information that you want to look at
          selectInput("demogSelect",
                      label = "Choose the Demographic Information to Map:",
                      choices = c("Total.Population", "Number.of.White.Residents", 
                                  "Number.of.Black.Residents", "Number.of.American.Indian.Residents",
                                  "Number.of.Asian.Residents", "Number.of.Hispanic.Latino.Residents",
                                  "Percentage.of.White.Residents", "Percentage.of.Black.Residents",
                                  "Percentage.of.American.Indian.Residents",
                                  "Percentage.of.Asian.Residents",
                                  "Percentage.of.Hispanic.Latino.Residents")),
          
          #adding an action button for the demographics select option
          actionButton("add_demog",
                       label = "Click to Change Demographic Information Displayed"),
          
          #creating some visual space 
          br(), br(),
          
          
          
           #shows the leaflet map
           leafletOutput("pittmap"),
          
          
          #creates some visual space
          br(), br(),
          
          
          #creates table display of map information
          dataTableOutput("demog_table")
        
          
          
          
          
          ),
  #Bike Share Distribution Exploration Page -----------------------------------------------
  tabItem("bikes",
          
          selectInput("per_select_1",
                      label = "Choose Demographic Information for First Line",
                      choices = c("Percentage.of.White.Residents", "Percentage.of.Black.Residents",
                                  "Percentage.of.American.Indian.Residents",
                                  "Percentage.of.Asian.Residents",
                                  "Percentage.of.Hispanic.Latino.Residents"
                                  )),

          selectInput("per_select_2",
                      label = "Choose Demographic Information for Second Line",
                      choices = c("Percentage.of.Black.Residents", "Percentage.of.White.Residents", 
                                  "Percentage.of.American.Indian.Residents",
                                  "Percentage.of.Asian.Residents",
                                  "Percentage.of.Hispanic.Latino.Residents"
                      )),

          
          plotlyOutput("numbikes_by_demo"),
          
          br(), br(),
          
          selectInput("census_tract",
                      label = "Select Census Tracts to Plot:",
                      choices = census_and_demog@data$census.tract,
                      multiple = TRUE,
                      selectize = TRUE,
                      selected = c("040500", "040400")),
          
        br(), br(),
        
        plotlyOutput("num_per_tract")
          
          
          
          ),
  
  
  #Full Dataset Page -----------------------------------------
  tabItem("fullData",
          
          #allows user to pick the columns they want to see in the data table
          selectInput(inputId = "columns",
                      label = "Pick the Columns You Want to Display:",
                      choices = c("Total.Population", "Number.of.White.Residents", 
                                  "Number.of.Black.Residents", "Number.of.American.Indian.Residents",
                                  "Number.of.Asian.Residents", "Number.of.Hispanic.Latino.Residents",
                                  "Percentage.of.White.Residents", "Percentage.of.Black.Residents",
                                  "Percentage.of.American.Indian.Residents",
                                  "Percentage.of.Asian.Residents",
                                  "Percentage.of.Hispanic.Latino.Residents"),
                      multiple = TRUE,
                      selectize = TRUE,
                      selected = c("Percentage.of.White.Residents", "Percentage.of.Black.Residents")),
          
          
          #creates download button for users
          downloadButton(outputId = "downloadData",
                         label = "Click to Download Full Dataset"),
          
          #creates some visual space between the two items
          br(), br(),
          
          dataTableOutput("full_data_table")
    
  )

)
  
  
)
  

 
ui <- dashboardPage(skin = "purple", header, sidebar, body)

# Define server logic ---------------------------------------
server <- function(input, output) {
  
  #subsets the census and demographics data to just the desired information
  full_data <- census_and_demog@data %>% 
    select(census.tract, Total.Population, Number.of.White.Residents, 
           Number.of.Black.Residents, Number.of.American.Indian.Residents,
           Number.of.Asian.Residents, Number.of.Hispanic.Latino.Residents,
           Percentage.of.White.Residents, Percentage.of.Black.Residents,
           Percentage.of.American.Indian.Residents,
           Percentage.of.Asian.Residents,
           Percentage.of.Hispanic.Latino.Residents,
           num.stations.per.tract)

  
        #adding basic labels to the leaflet map
        tract_labels <- reactive (
          sprintf("<strong> Census Tract: </strong>%s <br/> <strong>%s</strong>: %s <br/> <strong> Number of HealthyRide Stations: </strong> %s ",
                          census_and_demog$census.tract, input$demogSelect, 
                          prettyNum(census_and_demog[[input$demogSelect]], big.mark = ","),
                          census_and_demog$num.stations.per.tract) %>% # census_and_demog$Total.Population) %>% 
                         lapply(htmltools::HTML)
        )
        
        #customizes the label for the station markers
        station_marker_label <- sprintf("<strong> Station Name: </strong><br/> %s",
                                        stations$`Station Name`) %>% lapply(htmltools::HTML)

         output$pittmap <- renderLeaflet({
        
          #creates dynamic color palette changes for map
           pal <- colorNumeric("YlOrRd", domain = census_and_demog$Total.Population)
       

        
        #creates base map of Pittsburgh and locations of HealthyRide Stations
        pitt.map <- leaflet(data = stations) %>%
            #selecting a basemap
            addTiles(urlTemplate = "http://mt0.google.com/vt/lyrs=m&hl=en&x={x}&y={y}&z={z}&s=Ga", attribution = "Google", group = "Google") %>%
            addProviderTiles(provider = providers$Esri.NatGeoWorldMap, group = "NatGeo") %>% 
            #setting the view to just pittsburgh
            setView(-79.995888, 40.440624, 12)  %>% 
            addLayersControl(baseGroups = c("Google", "NatGeo")) %>% 
            addPolygons(data = census_and_demog,
                       weight = 2,
                       opacity = 1,
                        layerId = ~census_and_demog$tractce10,
                        fillOpacity = 0.7,
                        stroke = TRUE,
                        highlightOptions = highlightOptions(color = "black", 
                                                            weight = 5,
                                                            bringToFront = TRUE)) %>% 
            # #add markers on the map for the healthy ride bike station locations
            addMarkers(~Longitude, ~Latitude, 
                       label = station_marker_label,
                       clusterOptions = markerClusterOptions())
        
        pitt.map
        

      
    })
    
    
    
    
    
   #updates the map each time a new demographic select option is picked
    observeEvent(input$add_demog, {

      #change the criteria for the color palette based on demographic info input
      census_and_demog@data$select_demog <- census_and_demog@data[[input$demogSelect]]
      pal <- colorNumeric("YlOrRd", domain = census_and_demog$select_demog)
      

      leafletProxy("pittmap") %>%
       clearShapes() %>%
         addPolygons(data = census_and_demog,
                    weight = 2,
                    opacity = 1,
                    label = tract_labels(),
                    color = ~pal(select_demog),
                    fillOpacity = 0.7,
                    highlightOptions = highlightOptions(color = "black",
                                                        weight = 5,
                                                        bringToFront = TRUE))


    })

    
    #update the legend as needed based on new demographic information input
    observeEvent(input$add_demog, {

      census_and_demog@data$select_demog <- census_and_demog@data[[input$demogSelect]]
      pal <- colorNumeric("YlOrRd", domain = census_and_demog$select_demog)

      leafletProxy("pittmap", data = census_and_demog) %>%
        clearControls() %>%
        addLegend(pal = pal, values = ~select_demog, 
                  title = input$demogSelect,  position = "bottomright")
      

        

    })
    
    #creates a reactive dataset for just the inputs selected for the line graph
    full_data_subset <-  reactive({
      full_data %>% 
        select(input$per_select_1, input$per_select_2, num.stations.per.tract)
    })
    
    
    #plot of the change in  number bike share stations as the percent of a given demographic group increases
    output$numbikes_by_demo <- renderPlotly ({

      yvar <- "num.stations.per.tract"
      
    
      ggplotly(
        ggplot(full_data_subset(),
               aes_string(x = input$per_select_1, y = yvar)) +
          geom_line(color = "blue") +
          geom_line(aes_string(x = input$per_select_2), color = "red") +
          labs(x = "Percentage of Residents",
               y = "Number of HealthyRide Stations") +
          ggtitle("Number of HealthyRide Stations Vs. Percent Demographic Group"),
        
       

      )

    })
   
    
    #creates a dataset subset with just the census tracts selected by the user
    census_subset <- reactive({
      full_data %>% 
        filter(census.tract %in% input$census_tract) %>% 
        select(census.tract, num.stations.per.tract)
    })
    
    
    #creates a bar graph 
    output$num_per_tract <- renderPlotly ({


      ggplotly(
        ggplot(census_subset(),
               aes(x = census.tract, 
                   y = num.stations.per.tract,
                   fill = census.tract)) +
          geom_bar(stat = "identity") +
          labs(x = "Census Tracts",
            y = "Number of HealthyRide Stations") +
          ggtitle("Number of HealthyRide Stations per Census Tract"),
        
        tooltip = c("x", "y")

      )

    })
    
    
    #change the zoom level when the user clicks on a polygon
    observeEvent(input$pittmap_shape_click, {
        #if a census tract polygon is clicked, change the zoom
        click_tract <- input$pittmap_shape_click

        leafletProxy("pittmap") %>%
         setView(lng = click_tract$lng, lat = click_tract$lat, zoom = 15)
    })

   
    #subsets for the demographic information of interest for the map overivew page
    demog_subset <- eventReactive(input$add_demog,{
      census_and_demog@data %>% 
        select(census.tract, input$demogSelect, num.stations.per.tract) %>% 
        rename("Census Tract" = census.tract,
               "Number of HealthyRide Stations" = num.stations.per.tract)
    })

  
    
  #creates the datatable for the map overview page
   output$demog_table <- DT::renderDataTable(server = FALSE,{
       
       DT::datatable(data = demog_subset(),
                     extensions = 'Buttons',
                     rownames = FALSE,
                     options = list(
                       dom = 'Bfrtip',
                       buttons = c('csv', 'excel', 'pdf', 'print')
                     ))
   })
   
   
   
   
   #adds in the data to be downloaded in csv format
   output$downloadData <- downloadHandler(
     filename = "HealthyRide_Demographic_Distribution.csv",
     content = function(file) {
       write.csv(full_data, file, row.names = FALSE)
     }
   )
   
   #subsets the data to just the columns the user requests
   column_select <- reactive({
     full_data %>% 
       select(census.tract, input$columns, num.stations.per.tract)  %>% 
         rename("Census Tract" = census.tract,
                    "Number of HealthyRide Stations" = num.stations.per.tract)
             
   })
   
   
   #creates a datatable subset to just the desired information for the full dataset page
   output$full_data_table <- DT::renderDataTable({
     
     DT::datatable(data = column_select(),
                   rownames = FALSE)
   })
    
}

# Run the application 
shinyApp(ui = ui, server = server)
