% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/process-methods.R
\name{process.sequential_chat}
\alias{process.sequential_chat}
\title{Process a lot of prompts with a sequential chat}
\usage{
process.sequential_chat(
  chat_env,
  prompts,
  type = NULL,
  file = tempfile("chat_", fileext = ".rds"),
  progress = TRUE,
  beep = TRUE,
  echo = FALSE,
  ...
)
}
\arguments{
\item{chat_env}{The chat environment from seq_chat}

\item{prompts}{List of prompts to process}

\item{type}{Type specification for structured data extraction}

\item{file}{Path to save state file (.rds)}

\item{progress}{Whether to show progress bars}

\item{beep}{Whether to play a sound on completion}

\item{echo}{Whether to display chat outputs (when \code{progress} is \code{FALSE})}

\item{...}{Additional arguments passed to the chat method}
}
\value{
A process object with the processed results
}
\description{
Process a lot of prompts with a sequential chat
}
