### TODO:
  # -warnings
  # -handle C-c somehow ???
  # -discover source of package loading hang

library(rzmq)


### Global data
pbdenv <- new.env()

# options
pbdenv$prompt <- "pbdR"
pbdenv$port <- 5555

# internals
pbdenv$socket <- NULL

pbdenv$status <- list(
  ret               = invisible(),
  visible           = FALSE,
  lasterror         = NULL,
  num_warnings      = 0,
  warnings          = NULL,
  pbd_prompt_active = FALSE,
  should_exit       = FALSE,
  continuation      = FALSE
)

### just a pinch of sugar
get.status <- function(var)
{
  name <- as.character(substitute(name))
  pbdenv$status[[name]]
}

set.status <- function(var, val)
{
  name <- as.character(substitute(name))
  pbdenv$status[[name]] <- val
}



### ------------------------------------------------
pbd_readline <- function(input, continuation)
{
  if (continuation)
    symb <- "+ "
  else
    symb <- "> "
  
  prompt <- paste0(pbdenv$prompt, symb)
  
  if (pbdenv$whoami == "local")
  {
    ret <- c(input, readline(prompt=prompt))
    ret <- pbd_sanitize(inputs=ret)
  }
  else
    ret <- NULL
  
  return(ret)
}



pbd_sanitize <- function(inputs)
{
  for (i in 1:length(inputs))
  {
    input <- inputs[i]
    if (grepl(x=input, pattern="^(q\\(|quit\\()", perl=TRUE)) 
      inputs[i] <- "pbd_exit()"
    else if (grepl(x=input, pattern="^(\\?|\\?\\?|help\\()", perl=TRUE))
      stop("not supported") # FIXME make this an internal stop error
  }
  
  return(inputs)
}



is.error <- function(obj)
{
  if (inherits(obj, "try-error") || inherits(obj, "error"))
    return(TRUE)
  else
    return(FALSE)
}



pbd_repl_printer <- function()
{
  if (pbdenv$whoami == "remote") return(invisible())
  
#  cat("----------------------------\n")
#  print(ret)
#  cat("----------------------------\n")
  
  if (pbdenv$status$visible)
    cat(paste(pbdenv$status$ret, collapse="\n"), "\n")
  
  if (pbdenv$status$num_warnings > 0)
  {
    if (pbdenv$status$num_warnings > 10)
      cat(paste("There were", pbdenv$status$num_warnings, "warnings (use warnings() to see them)\n"))
    else
      print(warnings())
  }
  
  return(invisible())
}



pbd_interrupt <- function(x)
{
#  pbdenv$status$pbd_prompt_active <- TRUE
  cat("interrupt\n")
  print(x)
}



pbd_warning <- function(warn)
{
  pbdenv$status$num_warnings <- pbdenv$status$num_warnings + 1
  
  pbdenv$status$warnings <- append(pbdenv$status$warnings, conditionMessage(warn))
  invokeRestart("muffleWarning")
  print(warn)
}



pbd_error <- function(err)
{
  msg <- err$message
  pbdenv$status$continuation <- grepl(msg, pattern="unexpected end of input")
  
  if (!pbdenv$status$continuation)
  {
    msg <- sub(x=msg, pattern=" in eval\\(expr, envir, enclos\\) ", replacement="")
    pbdenv$status$lasterror <- paste0("Error: ", msg, "\n")
  }
  
  return(invisible())
}



pbd_show_errors <- function()
{
  if (!is.null(pbdenv$status$lasterror)) cat(pbdenv$status$lasterror)
  
  invisible()
}



pbd_show_warnings <- function()
{
  nwarnings <- length(pbdenv$status$warnings)
  
  if (!is.null(pbdenv$status$warnings)) 
  {
    if (nwarnings == 1)
    {
      cat("Warning message:\n")
      cat(pbdenv$status$warnings)
    }
    else if (nwarnings < 11)
    {
      cat("Warning message:\n")
      for (i in 1:nwarnings)
      {
        w <- pbdenv$status$warnings[i]
        cat(paste0(i, ": ", w))
      }
    }
    else
    {
      cat(paste("There were", nwarnings, "warnings (use warnings() to see them)"))
    }
    cat("\n")
  }
  
  invisible()
}



pbd_eval <- function(input, whoami, env)
{
  pbdenv$status$continuation <- FALSE
  pbdenv$status$lasterror <- NULL
  
  if (whoami == "local")
  {
    send.socket(pbdenv$socket, data=input)
    
    pbdenv$status <- receive.socket(pbdenv$socket)
    
    pbd_show_errors()
    pbd_show_warnings()
  }
  else if (whoami == "remote")
  {
    cat("Awaiting message:  ")
    msg <- receive.socket(pbdenv$socket)
    cat(msg, "\n")
    
    ret <- 
    withCallingHandlers(
      tryCatch({
          pbdenv$visible <- withVisible(eval(parse(text=msg), envir=env))
        }, interrupt=pbd_interrupt, error=pbd_error
      ), warning=pbd_warning
    )
    
    if (!is.null(ret))
    {
      pbdenv$status$visible <- ret$visible
      
      if (!ret$visible)
      pbdenv$status$ret <- NULL
    else
      pbdenv$status$ret <- capture.output(ret$value)
    }
    
    send.socket(pbdenv$socket, pbdenv$status)
  }
  else
    stop("bad 'whoami'")
}



pbd_exit <- function()
{
  pbdenv$status$should_exit <- TRUE
  
  return(invisible())
}



pbd_repl_init <- function()
{
  if (!pbdenv$status$pbd_prompt_active)
    pbdenv$status$pbd_prompt_active <- TRUE
  else
  {
    cat("The pbd repl is already running!\n")
    return(FALSE)
  }
  
  ### Initialize zmq
  if (pbdenv$whoami == "local")
  {
    context <- init.context()
    
    socket <- init.socket(context, "ZMQ_REQ")
    pbdenv$socket <- socket
    
    connect.socket(socket, paste0("tcp://localhost:", pbdenv$port))
  }
  else if (pbdenv$whoami == "remote")
  {
    context <- init.context()
    
    socket <- init.socket(context,"ZMQ_REP")
    pbdenv$socket <- socket
    
    bind.socket(socket, paste0("tcp://*:", pbdenv$port))
  }
  
  return(TRUE)
}



pbd_repl <- function(env=sys.parent())
{
  ### FIXME needed?
  if (!interactive() && pbdenv$whoami == "local")
  {
    stop("You should only use this interactively")
  }
  
  
  init <- pbd_repl_init()
  if (!init) return(invisible())
  
  
  ### the repl
  while (TRUE)
  {
    input <- character(0)
    pbdenv$status$continuation <- FALSE
    
    while (TRUE)
    {
      pbdenv$visible <- withVisible(invisible())
      input <- pbd_readline(input=input, continuation=pbdenv$status$continuation)
      
      pbd_eval(input=input, whoami=pbdenv$whoami, env=env)
      
      if (pbdenv$status$continuation) next
      
      pbd_repl_printer()
      
      ### Should go after all other evals and handlers
      if (pbdenv$status$should_exit)
      {
        pbdenv$pbd_prompt_active <- pbdenv$status$should_exit <- FALSE
        return(invisible())
      }
      
      break
    }
  }
  
  pbdenv$pbd_prompt_active <- pbdenv$status$should_exit <- FALSE
  return(invisible())
}


