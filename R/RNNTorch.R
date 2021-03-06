# @file RNNTorch.R
#
# Copyright 2018 Observational Health Data Sciences and Informatics
#
# This file is part of PatientLevelPrediction
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#' Create setting for RNN model with python 
#' @param hidden_size  The hidden size
#' @param epochs     The number of epochs
#' @param seed       A seed for the model
#' @param class_weight   The class weight used for imbalanced data: 
#'                           0: Inverse ratio between positives and negatives
#'                          -1: Focal loss
#' @param type      It can be normal 'RNN', 'BiRNN' (bidirectional RNN) and 'GRU'
#'
#' @examples
#' \dontrun{
#' model.rnnTorch <- setRNNTorch()
#' }
#' @export
setRNNTorch <- function(hidden_size=c(50, 100), epochs=c(20, 50), seed=0, class_weight = 0, type = 'RNN'){
  
  # test python is available and the required dependancies are there:
  checkPython()
  
  result <- list(model='fitRNNTorch', param=split(expand.grid(hidden_size=hidden_size,
                                            epochs=epochs, seed=ifelse(is.null(seed),'NULL', seed), 
                                            class_weight = class_weight, type = type),
									        1:(length(hidden_size)*length(epochs)) ),
                                      name='RNN Torch')
  
  class(result) <- 'modelSettings' 
  
  return(result)
}

fitRNNTorch <- function(population, plpData, param, search='grid', quiet=F,
                        outcomeId, cohortId, ...){
  
  # check plpData is libsvm format or convert if needed
  if(!'ffdf'%in%class(plpData$covariates))
    stop('Needs plpData')
  
  if(colnames(population)[ncol(population)]!='indexes'){
    warning('indexes column not present as last column - setting all index to 1')
    population$indexes <- rep(1, nrow(population))
  }
  
  # connect to python if not connected
  initiatePython()
  
  start <- Sys.time()
  
  population$rowIdPython <- population$rowId-1  #to account for python/r index difference #subjectId
  #idx <- ffbase::ffmatch(x = population$subjectId, table = ff::as.ff(plpData$covariates$rowId))
  #idx <- ffbase::ffwhich(idx, !is.na(idx))
  #population <- population[idx, ]
  
  PythonInR::pySet('population', as.matrix(population[,c('rowIdPython','outcomeCount','indexes')]) )
  
  # convert plpData in coo to python:
  #covariates <- plpData$covariates
  #covariates$rowIdPython <- covariates$rowId -1 #to account for python/r index difference
  #PythonInR::pySet('covariates', as.matrix(covariates[,c('rowIdPython','covariateId','timeId', 'covariateValue')]))
  
  result <- toSparseTorchPython(plpData,population,map=NULL, temporal=T)
  # save the model to outLoc  TODO: make this an input or temp location?
  outLoc <- file.path(getwd(),'python_models')
  # clear the existing model pickles
  for(file in dir(outLoc))
    file.remove(file.path(outLoc,file))

  #covariateRef$value <- unlist(varImp)

  outLoc <- file.path(getwd(),'python_models')
  PythonInR::pySet("modelOutput",outLoc)

  # do cross validation to find hyperParameter
  hyperParamSel <- lapply(param, function(x) do.call(trainRNNTorch, c(x, train=TRUE)  ))
 
  hyperSummary <- cbind(do.call(rbind, param), unlist(hyperParamSel))
  
  #now train the final model and return coef
  bestInd <- which.max(abs(unlist(hyperParamSel)-0.5))[1]
  finalModel <- do.call(trainRNNTorch, c(param[[bestInd]], train=FALSE))

  covariateRef <- ff::as.ram(plpData$covariateRef)
  incs <- rep(1, nrow(covariateRef)) 
  covariateRef$included <- incs
  covariateRef$covariateValue <- rep(0, nrow(covariateRef))
  
  modelTrained <- file.path(outLoc) 
  param.best <- param[[bestInd]]
  
  comp <- start-Sys.time()
  
  # return model location 
  result <- list(model = modelTrained,
                 trainCVAuc = -1, # ToDo decide on how to deal with this
                 hyperParamSearch = hyperSummary,
                 modelSettings = list(model='fitRNNTorch',modelParameters=param.best),
                 metaData = plpData$metaData,
                 populationSettings = attr(population, 'metaData'),
                 outcomeId=outcomeId,
                 cohortId=cohortId,
                 varImp = covariateRef, 
                 trainingTime =comp,
                 dense=1,
                 covariateMap=result$map # I think this is need for new data to map the same?
                 
  )
  class(result) <- 'plpModel'
  attr(result, 'type') <- 'python'
  attr(result, 'predictionType') <- 'binary'
  
  return(result)
}


trainRNNTorch <- function(epochs=50, hidden_size = 100, seed=0, class_weight= 0, type = 'RNN', train=TRUE){
  #PythonInR::pyExec(paste0("size = ",size))
  PythonInR::pyExec(paste0("epochs = ",epochs))
  PythonInR::pyExec(paste0("hidden_size = ",hidden_size))
  PythonInR::pyExec(paste0("seed = ",seed))
  #PythonInR::pyExec(paste0("time_window = ",time_window))
  PythonInR::pyExec(paste0("class_weight = ",class_weight))
    if (type == 'RNN'){
    PythonInR::pyExec("model_type = 'RNN'")
  } else if (type == 'BiRNN'){
    PythonInR::pyExec("model_type = 'BiRNN'")
  } else if (type == 'GRU'){
    PythonInR::pyExec("model_type = 'GRU'")
  }
  if(train)
    PythonInR::pyExec("train = True")
  if(!train)
    PythonInR::pyExec("train = False")
  python_dir <- system.file(package='PatientLevelPrediction','python')
  PythonInR::pySet("python_dir", python_dir)  
  # then run standard python code
  PythonInR::pyExecfile(system.file(package='PatientLevelPrediction','python','deepTorch.py'))
  
  if(train){
    # then get the prediction 
    pred <- PythonInR::pyGet('prediction', simplify = FALSE)
    pred <-  apply(pred,1, unlist)
    pred <- t(pred)
    colnames(pred) <- c('rowId','outcomeCount','indexes', 'value')
    pred <- as.data.frame(pred)
    attr(pred, "metaData") <- list(predictionType="binary")
    
    pred$value <- 1-pred$value
    auc <- PatientLevelPrediction::computeAuc(pred)
    writeLines(paste0('Model obtained CV AUC of ', auc))
    return(auc)
  }
  
  return(T)
  
}
