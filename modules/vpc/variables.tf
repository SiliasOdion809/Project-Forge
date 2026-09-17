variable "project_name" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "Map of public subnets, e.g. { a = { cidr = \"10.0.0.0/24\", az = \"us-east-1a\" } }"
  type = map(object({
    cidr = string
    az   = string
  }))
}

variable "private_subnets" {
  description = "Map of private subnets"
  type = map(object({
    cidr = string
    az   = string
  }))
}