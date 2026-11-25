variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "db_username" {
  type    = string
  default = "backstage_admin"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}