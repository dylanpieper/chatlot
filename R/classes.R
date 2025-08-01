#' Extract texts or structured data from a process response
#' @name texts
#' @param x A process object
#' @param ... Additional arguments passed to methods
#' @return A character vector or list of text responses. If a type specification is provided to the batch, return structured data.
#' @examplesIf ellmer::has_credentials("openai")
#' # Create a chat processor
#' chat <- seq_chat("openai/gpt-4.1")
#'
#' # Process a batch of prompts
#' response <- chat$process(list(
#'   "What is R?",
#'   "Explain base R versus tidyverse",
#'   "Explain vectors, lists, and data frames"
#' ))
#'
#' # Extract text responses
#' response$texts()
#' @export
texts <- S7::new_generic("texts", "x")

#' Extract chat objects from a process response
#' @name chats
#' @param x A process object
#' @param ... Additional arguments
#' @return A list of chat objects
#' @examplesIf ellmer::has_credentials("openai")
#' # Create a chat processor
#' chat <- seq_chat("openai/gpt-4.1")
#'
#' # Process a batch of prompts
#' response <- chat$process(list(
#'   "What is R?",
#'   "Explain base R versus tidyverse",
#'   "Explain vectors, lists, and data frames"
#' ))
#'
#' # Return the chat objects
#' response$chats()
#' @export
chats <- S7::new_generic("chats", "x")

#' Get progress information from a process response
#' @name progress
#' @param x A process object
#' @param ... Additional arguments passed to methods
#' @return A list containing progress details
#' @examplesIf ellmer::has_credentials("openai")
#' # Create a chat processor
#' chat <- seq_chat("openai/gpt-4.1")
#'
#' # Process a batch of prompts
#' response <- chat$process(list(
#'   "What is R?",
#'   "Explain base R versus tidyverse",
#'   "Explain vectors, lists, and data frames"
#' ))
#'
#' # Check the progress
#' response$progress()
#' @export
progress <- S7::new_generic("progress", "x")

#' Process response class for managing chat processing
#' @param prompts List of prompts to process
#' @param responses List to store responses
#' @param completed Integer indicating number of completed prompts
#' @param file Path to save state file (.rds)
#' @param type Type specification for structured data extraction
#' @param progress Whether to show progress bars (default: TRUE)
#' @param input_type Type of input ("vector" or "list")
#' @param chunk_size Size of chunks for parallel processing
#' @param workers Number of parallel workers
#' @param state Internal state tracking
#' @param beep Play sound on completion (default: TRUE)
#' @param echo Whether to echo messages during processing (default: FALSE)
#' @return Returns an S7 class object of class "process" that represents a collection of prompts and their responses from chat models. The object contains all input parameters as properties and provides methods for:
#' \itemize{
#'   \item Extracting text responses via \code{texts()} (includes structured data when a type specification is provided)
#'   \item Accessing full chat objects via \code{chats()}
#'   \item Tracking processing progress via \code{progress()}
#' }
#' The process object manages prompt processing and tracks completion status.
#' @examplesIf ellmer::has_credentials("openai")
#' # Create a chat processor
#' chat <- seq_chat("openai/gpt-4.1")
#'
#' # Process a batch of prompts
#' response <- chat$process(list(
#'   "What is R?",
#'   "Explain base R versus tidyverse",
#'   "Explain vectors, lists, and data frames"
#' ))
#'
#' # Check the progress if interrupted
#' response$progress()
#'
#' # Return the responses as a vector or list
#' response$texts()
#'
#' # Return the chat objects
#' response$chats()
#' @export
process <- S7::new_class(
  "process",
  properties = list(
    prompts = S7::new_property(
      class = S7::class_list,
      validator = function(value) {
        if (is.null(value) || length(value) == 0) {
          return("must not be NULL or empty")
        }

        all_simple <- all(purrr::map_lgl(value, function(x) {
          is.character(x) && length(x) == 1 && nchar(x) > 0
        }))

        if (all_simple) {
          return(NULL)
        }
        all_valid <- all(purrr::map_lgl(value, function(x) {
          if (is.character(x)) {
            return(length(x) > 0 && any(nchar(x) > 0))
          } else if (is.vector(x) || is.list(x)) {
            return(length(x) > 0)
          } else {
            return(TRUE)
          }
        }))

        if (!all_valid) {
          return("must be a list of valid prompts (character strings for simple prompts, or mixed content with ellmer functions for complex prompts)")
        }

        NULL
      }
    ),
    responses = S7::new_property(
      class = S7::class_list,
      validator = function(value) NULL
    ),
    completed = S7::new_property(
      class = S7::class_integer,
      validator = function(value) {
        if (length(value) != 1) {
          "must be a single integer"
        }
        if (value < 0) {
          "must be non-negative"
        }
        NULL
      }
    ),
    file = S7::class_character | NULL,
    type = S7::new_property(
      class = S7::class_any | NULL,
      validator = function(value) {
        if (!is.null(value)) {
          if (!inherits(value, c("ellmer::TypeObject", "ellmer::Type", "ellmer::TypeArray"))) {
            "must be an ellmer type specification (created with type_object(), type_array(), etc.) or NULL"
          }
        }
        NULL
      }
    ),
    progress = S7::new_property(
      class = S7::class_logical,
      validator = function(value) {
        if (length(value) != 1) {
          "must be a single logical value"
        }
        NULL
      }
    ),
    input_type = S7::new_property(
      class = S7::class_character,
      validator = function(value) {
        if (!value %in% c("vector", "list")) {
          "must be either 'vector' or 'list'"
        } else {
          NULL
        }
      }
    ),
    chunk_size = S7::new_property(
      class = S7::class_integer | NULL,
      validator = function(value) {
        if (!is.null(value)) {
          if (length(value) != 1) {
            "must be a single integer"
          }
          if (value <= 0) {
            "must be positive"
          }
        }
        NULL
      }
    ),
    workers = S7::new_property(
      class = S7::class_integer | NULL,
      validator = function(value) {
        if (!is.null(value)) {
          if (length(value) != 1) {
            "must be a single integer"
          }
          if (value <= 0) {
            "must be positive"
          }
        }
        NULL
      }
    ),
    beep = S7::new_property(
      class = S7::class_logical,
      validator = function(value) {
        if (length(value) != 1) {
          "must be a single logical value"
        }
        NULL
      }
    ),
    echo = S7::new_property(
      class = S7::new_union(S7::class_logical, S7::class_character),
      validator = function(value) {
        if (length(value) != 1) {
          "must be a single logical value or one of 'none', 'text', or 'all'"
        }

        if (is.character(value) && !value %in% c("none", "text", "all")) {
          "must be a logical value or one of 'none', 'text', or 'all'"
        }

        NULL
      }
    ),
    state = S7::new_property(
      class = S7::class_list | NULL,
      validator = function(value) {
        if (!is.null(value)) {
          required_fields <- c("active_workers", "failed_chunks", "retry_count")
          if (!all(required_fields %in% names(value))) {
            "must contain active_workers, failed_chunks, and retry_count"
          }
        }
        NULL
      }
    )
  ),
  validator = function(self) {
    if (self@completed > length(self@prompts)) {
      "cannot be larger than number of prompts"
    }
    if (!is.null(self@state)) {
      if (self@state$active_workers > self@workers) {
        "active workers cannot exceed total workers"
      }
    }
    NULL
  }
)

#' Convert list to dataframe if structure allows
#'
#' @param x A list object
#' @return A dataframe if conversion possible, otherwise original list
#' @keywords internal
#' @noRd
list_to_df <- function(x) {
  if (is.list(x) &&
    all(sapply(x, is.list)) &&
    length(unique(lapply(x, names))) == 1) {
    do.call(rbind, lapply(x, data.frame))
  } else {
    x
  }
}

#' @keywords internal
#' @noRd
S7::method(texts, process) <- function(x, flatten = TRUE) {
  responses <- x@responses[seq_len(x@completed)]

  extract_text <- function(response) {
    if (is.null(response)) {
      return(NA_character_)
    }

    if (!is.null(response$structured_data)) {
      return(response$structured_data)
    }

    if (!is.null(response$text)) {
      return(response$text)
    }

    NA_character_
  }

  values <- purrr::map(responses, extract_text)

  if (x@input_type == "vector" && flatten && all(purrr::map_lgl(values, is.character))) {
    return(unlist(values))
  } else {
    return(list_to_df(values))
  }
}

#' @keywords internal
#' @noRd
S7::method(chats, process) <- function(x) {
  responses <- x@responses[seq_len(x@completed)]
  purrr::map(responses, "chat")
}

#' @keywords internal
#' @noRd
S7::method(progress, process) <- function(x) {
  list(
    total_prompts = length(x@prompts),
    completed_prompts = x@completed,
    completion_percentage = (x@completed / length(x@prompts)) * 100,
    remaining_prompts = length(x@prompts) - x@completed,
    file = x@file
  )
}
