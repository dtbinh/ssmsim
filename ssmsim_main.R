##################
###   Setup    ###
##################
set.seed(123)
options(java.parameters = "-Xmx12288m")  # increase Java heap size. 
# default heap size is only 512 MB, increase to 12 GB 
# must do before loading rJava package

library(RNetLogo)  # loads rJava package
library(plyr)
library(dplyr)  # plyr MUST be loaded before dplyr
library(tidyr)
library(stringr)
library(ggplot2)
library(igraph)
library(yaml)

## This code should be run from the ssmsim project directory
## Otherwise, set the project path manually, e.g.
# project.path <- "/Users/cgilroy/Documents/Research/ssmsim"
## Note that you shouldn't change the working directory after
## starting NetLogo
project.path <- getwd()
nl.path <- file.path(project.path, "NetLogo") 
r.path <- file.path(project.path, "R")
model.path <- file.path(nl.path, "ssmsim.nlogo")

source(file.path(r.path, "ssmsim_netlogo.R"))
source(file.path(r.path, "ssmsim_networks.R"))
source(file.path(r.path, "ssmsim_data_cleaning.R"))
source(file.path(r.path, "ssmsim_output.R"))

run.config <- yaml.load_file(file.path(project.path, "run_config.yml"))

## Each run path has a different yaml config file 
## with a different set of parameters
lapply(run.config$run_path, function(run) { 
  run.path <- file.path(project.path, "model_runs", run)
  ## read config file with parameters for specific set of model runs
  config <- yaml.load_file(file.path(run.path, "ssmsim_config.yml"))
  
  ## run simulations in NetLogo
  Sys.setenv(NOAWT=1)  # need to set this to run headless
  NLStart(nl.path, gui=FALSE)
  NLLoadModel(model.path)
  
  ##################
  ### Model Runs ###
  ##################

  ## pull parameters from config file and process as necessary
  trait_dist <- if(config$homophily) distributeTraitPreferentially() else distributeTraitRandomly()
  ally_delay <- if(config$allies) 0 else config$max_ticks
  support_dist <- eval(parse(text = config$support_dist))
  network_type <- eval(parse(text = config$network_type))
  num_lgbts <- floor(config$pct/100 * config$num_nodes)
  
  gs <- replicate(config$runs, 
                  generateNetwork(num.nodes = config$num_nodes, 
                                  num.lgbts = num_lgbts, 
                                  sampleNetwork = network_type,
                                  distributeTrait = trait_dist, 
                                  distributeSupport = support_dist), 
                  simplify = FALSE)
  fs <- generateNetworkFiles(gs, dir = run.path, subdir = "")
  rm(gs)  # remove graph objects to save memory
  
  results <- 
    runSimulations(fs, 
                   ticks = config$max_ticks, 
                   growth.fn = "grow-exp", 
                   random.fn = "random-support", 
                   response.fn = "respond-transition-matrix", 
                   coming.out.delay = 0, 
                   ally.delay = ally_delay, 
                   lambda = config$lambda)
  
  NLQuit()
  Sys.unsetenv("NOAWT")  # unset environment variable
  
  run.name <- 
    Map(paste0, names(config[1:6]), config[1:6]) %>% 
    Reduce(function(x, y) paste(x, y, sep = "_"), x = .) 
  
  ##################
  ### Model Plots ##
  ##################
  
  tick_list <- seq(0, config$max_ticks, by=10)
  poll.plot.title <- 
    sprintf(
      "1%% Sample; Degree = %i; %% = %.0f; lambda = %.0f;\nhomophily = %s; allies = %s", 
      config$degree, config$pct, config$lambda, 
      config$homophily, config$allies
    )
  poll.plot <- 
    results %>%
    sampleSupport(sample_proportion=0.01) %>% 
    pollSupport(mid_break=.2) %>% 
    filter(tick %in% tick_list) %>%
    group_by(tick, support_level) %>%
    summarise(count = mean(count)) %>%  # plot mean fraction over multiple runs
    plotPoll(num.nodes=.01*config$num_nodes) + geom_line() + 
    ggtitle(poll.plot.title)
  poll.plot.file.name <- 
    file.path(run.path, 
              paste0("poll_plot_", run.name))
  ggsave(filename = paste0(poll.plot.file.name, ".png"), 
         plot = poll.plot, 
         width = 8, height = 5)
  ## Save gg object so that plots can be grouped and modified later 
  saveRDS(object = poll.plot,
          file = paste0(poll.plot.file.name, ".Rds"))
  
  support.plot.title <- 
    sprintf(
      "Support; Degree = %i; %% = %.0f; lambda = %.0f;\nhomophily = %s; allies = %s", 
      config$degree, config$pct, config$lambda, 
      config$homophily, config$allies
    )
  support.plot <- 
    results %>% 
    filter(run == "1") %>%  # only plot distribution from first run
    plotSupport(ticks = c(1, seq(50, config$max_ticks, by = 50))) + 
    ggtitle(support.plot.title)
  support.plot.file.name <- 
    file.path(run.path, 
              paste0("support_plot_", run.name, ".png"))
  ggsave(filename = support.plot.file.name, 
         plot = support.plot, 
         width = 8, height = 5)
  
  ##################
  ### Model Data ###
  ##################
  
  ## save max value of proportion supportive
  ## save time point at which supportive > opposed
  metrics <- 
    results %>%
    group_by(run) %>%
    do(
      reportComparisonMetrics(., num.nodes = config$num_nodes) %>%
        transmute(lambda = config$lambda, 
                  percent = config$pct, 
                  num_nodes = config$num_nodes,
                  allies = config$allies, 
                  homophily = config$homophily,
                  degree = as.integer(config$degree),
                  variable = variable,
                  value = value)
    ) %>%
    ungroup()
  ## NOTE: `degree = config$degree` throws an error:
  ## "Error: invalid subscript type 'closure'"
  
  metrics.file.name <- file.path(run.path, 
                                 paste(run.name, "csv", sep = "."))
  write.csv(metrics, file = metrics.file.name, 
            row.names = FALSE)
  
  ## Remove network files to save space
  lapply(fs, file.remove)
  rm(results)
})